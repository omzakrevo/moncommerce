import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as xlsx;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path_provider/path_provider.dart';
import 'receipt_printing.dart';
import 'local_staff.dart';
import 'local_staff_page.dart';
import 'product_import.dart';
import 'inventory_dialog.dart';
import 'stock_value.dart';
import 'shop_account.dart';
import 'shop_sync.dart';
import 'shop_preferences.dart';
part 'src/admin_pages.dart';
part 'src/app_shell.dart';
part 'src/auth_pages.dart';
part 'src/commercial_documents.dart';
part 'src/dashboard.dart';
part 'src/models.dart';
part 'src/more_pages.dart';
part 'src/products_page.dart';
part 'src/reports_pages.dart';
part 'src/sales.dart';
part 'src/scanner.dart';
part 'src/storefront.dart';


const _supabaseUrl = 'https://vcmisyzfoermqcvmszpa.supabase.co';
const _supabasePublishableKey =
    'sb_publishable_OWtwuxDeHflzznumnhDPIw_K-nVhUhl';
const _storefrontBaseUrl = 'https://moncommerce.omzakrevo.chatgpt.site';
const _offlineAccessKey = 'offline_access_granted_v1';
const _offlineUserIdKey = 'offline_access_user_id_v1';
const _licenseCacheKey = 'license_cache_v1';
const _updateInstallerChannel = MethodChannel('bf.moncommerce/app_updates');
bool _supabaseReady = false;
bool _firebaseReady = false;
bool _localStaffSession = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
    _firebaseReady = true;
    if (Platform.isAndroid || Platform.isIOS) {
      FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
    }
  } catch (_) {}
  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _supabasePublishableKey,
  );
  _supabaseReady = true;
  final defaultFlutterErrorHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    defaultFlutterErrorHandler?.call(details);
    unawaited(
      _logActivity(
        'app_error',
        details.exceptionAsString(),
        severity: 'error',
        metadata: {
          'library': details.library ?? '',
          'context': details.context?.toDescription() ?? '',
        },
      ),
    );
  };
  runApp(const MonCommerceApp());
  if (_firebaseReady && (Platform.isAndroid || Platform.isIOS)) {
    unawaited(_initializePushNotifications());
  }
}

SupabaseClient get supabase => Supabase.instance.client;

Future<bool> _hasInternetConnection() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client
        .getUrl(Uri.parse(_supabaseUrl))
        .timeout(const Duration(seconds: 2));
    final response = await request.close().timeout(const Duration(seconds: 2));
    return response.statusCode > 0;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<void> _cacheLicenseVerification() async {
  final userId = supabase.auth.currentUser?.id;
  if (userId == null) return;
  try {
    final rows = await supabase
        .from('licenses')
        .select('plan, status, key_hint, expires_at')
        .order('created_at', ascending: false)
        .limit(1)
        .timeout(const Duration(seconds: 5));
    final row = rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _licenseCacheKey,
      jsonEncode({
        'userId': userId,
        'verifiedAt': DateTime.now().toIso8601String(),
        'license': row,
      }),
    );
  } catch (_) {
    // Une vérification de licence ne doit jamais bloquer l'accès local.
  }
}

Future<Map<String, dynamic>?> _cachedLicense() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_licenseCacheKey);
  if (raw == null) return null;
  try {
    final cached = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    final cachedUserId = cached['userId'] as String?;
    final localUserId =
        supabase.auth.currentUser?.id ??
        preferences.getString(_offlineUserIdKey);
    if (cachedUserId == null || cachedUserId != localUserId) return null;
    final license = cached['license'];
    return license is Map ? Map<String, dynamic>.from(license) : null;
  } catch (_) {
    return null;
  }
}

bool _isNewerVersion(String candidate, String current) {
  List<int> parse(String value) => value
      .split(RegExp(r'[.+-]'))
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final candidateParts = parse(candidate);
  final currentParts = parse(current);
  final length = candidateParts.length > currentParts.length
      ? candidateParts.length
      : currentParts.length;
  for (var index = 0; index < length; index++) {
    final candidateValue = index < candidateParts.length
        ? candidateParts[index]
        : 0;
    final currentValue = index < currentParts.length ? currentParts[index] : 0;
    if (candidateValue != currentValue) return candidateValue > currentValue;
  }
  return false;
}

Future<String> _downloadUpdateApk(
  String url,
  String version,
  ValueChanged<double> onProgress,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Téléchargement indisponible (${response.statusCode})',
      );
    }
    final directory = Directory(
      '${Directory.systemTemp.path}/moncommerce-updates',
    );
    await directory.create(recursive: true);
    final safeVersion = version.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '-');
    final file = File('${directory.path}/moncommerce-$safeVersion.apk');
    final output = file.openWrite();
    var received = 0;
    final total = response.contentLength;
    try {
      await for (final chunk in response) {
        output.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
    } finally {
      await output.close();
    }
    onProgress(1);
    return file.path;
  } finally {
    client.close(force: true);
  }
}

Future<void> _installUpdateApk(String path) =>
    _updateInstallerChannel.invokeMethod('installApk', {'path': path});

const _appVersion = '1.0.0';

Future<void> _updatePresence({
  required String lastAction,
  bool newSession = false,
}) async {
  if (!_supabaseReady) return;
  final user = supabase.auth.currentUser;
  if (user == null) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = <String, dynamic>{
      'user_id': user.id,
      'shop_name': prefs.getString('shop_name') ?? '',
      'app_version': _appVersion,
      'platform': Platform.operatingSystem,
      'last_action': lastAction,
      'last_seen': now,
    };
    if (newSession) payload['session_started_at'] = now;
    await supabase
        .from('app_user_presence')
        .upsert(payload, onConflict: 'user_id');
  } catch (_) {
    // Le monitoring ne doit jamais bloquer les fonctions de caisse.
  }
}

Future<void> _logActivity(
  String eventType,
  String description, {
  String severity = 'info',
  Map<String, dynamic> metadata = const {},
  bool newSession = false,
}) async {
  if (!_supabaseReady || _localStaffSession) return;
  final user = supabase.auth.currentUser;
  if (user == null) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await supabase.from('app_activity_logs').insert({
      'user_id': user.id,
      'shop_name': prefs.getString('shop_name') ?? '',
      'event_type': eventType,
      'description': description,
      'severity': severity,
      'metadata': metadata,
      'app_version': _appVersion,
      'platform': Platform.operatingSystem,
    });
    await _updatePresence(lastAction: eventType, newSession: newSession);
  } catch (_) {
    // L'activité locale reste prioritaire lorsque le cloud est indisponible.
  }
}

const _green = Color(0xFF2F6BE8);
const _dark = Color(0xFF0F1F46);
const _cream = Color(0xFFEFF1F4);
const _orange = Color(0xFFF0A33A);

final _localNotifications = FlutterLocalNotificationsPlugin();
const _notificationChannel = AndroidNotificationChannel(
  'moncommerce_alerts',
  'Notifications MonCommerce',
  description: 'Annonces et mises à jour envoyées par MonCommerce',
  importance: Importance.max,
);

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

Future<void> _initializePushNotifications() async {
  await _localNotifications.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  final android = _localNotifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await android?.createNotificationChannel(_notificationChannel);
  await android?.requestNotificationsPermission();
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
  await FirebaseMessaging.instance.subscribeToTopic('all_users');
  FirebaseMessaging.onMessage.listen((message) async {
    final notification = message.notification;
    if (notification == null) return;
    await _localNotifications.show(
      id: message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
      title: notification.title ?? 'MonCommerce',
      body: notification.body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'moncommerce_alerts',
          'Notifications MonCommerce',
          channelDescription:
              'Annonces et mises à jour envoyées par MonCommerce',
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: message.data['announcement_id']?.toString(),
    );
  });
}

class MonCommerceApp extends StatelessWidget {
  const MonCommerceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MonCommerce',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _cream,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _green,
          primary: _green,
          surface: Colors.white,
        ),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 1.5,
          shadowColor: Color(0x1A0F1F46),
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFFE5E7EB)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: Color(0xFFE5E7EB)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _green,
            minimumSize: const Size(48, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        navigationRailTheme: NavigationRailThemeData(
          backgroundColor: Colors.white,
          indicatorColor: _green,
          indicatorShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          selectedIconTheme: const IconThemeData(color: Colors.white),
          unselectedIconTheme: const IconThemeData(color: Color(0xFF9CA3AF)),
          selectedLabelTextStyle: const TextStyle(
            color: _green,
            fontWeight: FontWeight.w800,
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          indicatorColor: _green,
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? Colors.white
                  : const Color(0xFF9CA3AF),
            ),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}
