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

const _green = Color(0xFF126A4A);
const _dark = Color(0xFF12352B);
const _cream = Color(0xFFF5F7F3);
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
        colorScheme: ColorScheme.fromSeed(seedColor: _green),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(18)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _loading = true;
  bool _connected = false;
  bool _offlineMode = false;
  bool _isSuperAdmin = false;
  String _shopName = 'Boutique Wendé';
  String _storageUserId = 'offline';
  LocalStaffAccount? _staffAccount;
  bool _localLoginScreen = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(localStaffLoginRequiredKey) == true) {
      if (mounted)
        setState(() {
          _loading = false;
          _localLoginScreen = true;
        });
      return;
    }
    final online = await _hasInternetConnection();
    final currentUser = supabase.auth.currentUser;
    final cachedUserId = preferences.getString(_offlineUserIdKey);
    final hasOfflineAccess =
        preferences.getBool(_offlineAccessKey) == true &&
        cachedUserId != null &&
        cachedUserId.isNotEmpty;
    final connected = currentUser != null || hasOfflineAccess;
    if (currentUser != null || cachedUserId != null) {
      await activateShopPreferences(
        preferences,
        currentUser?.id ?? cachedUserId!,
        legacyOwner: cachedUserId,
      );
    }
    var isAdmin = preferences.getBool('is_super_admin_v1') ?? false;
    final restoredUserId = currentUser?.id ?? cachedUserId;
    var restoredShopName =
        preferences.getString('shop_name_$restoredUserId') ??
        (cachedUserId == restoredUserId
            ? preferences.getString('shop_name')
            : null);
    if (online && currentUser != null) {
      try {
        final remoteName = await ShopAccountService(
          supabase,
        ).shopName(currentUser.id).timeout(const Duration(seconds: 10));
        if (remoteName != null) {
          restoredShopName = remoteName;
          await preferences.setString(
            'shop_name_${currentUser.id}',
            remoteName,
          );
          await preferences.setString('shop_name', remoteName);
        }
      } catch (_) {
        /* Keep the last verified name while the server is unavailable. */
      }
      try {
        isAdmin =
            await supabase
                    .rpc('is_super_admin')
                    .timeout(const Duration(seconds: 5))
                as bool? ??
            false;
      } catch (_) {
        isAdmin = preferences.getBool('is_super_admin_v1') ?? false;
      }
      await preferences.setBool('is_super_admin_v1', isAdmin);
      await preferences.setBool(_offlineAccessKey, true);
      await preferences.setString(_offlineUserIdKey, currentUser.id);
      unawaited(_cacheLicenseVerification());
      unawaited(_logActivity('app_open', 'Application ouverte'));
    }
    if (!mounted) return;
    setState(() {
      _connected = connected && restoredShopName != null;
      _offlineMode = !online;
      _isSuperAdmin = isAdmin;
      _shopName = restoredShopName ?? 'Ma boutique';
      _storageUserId = currentUser?.id ?? cachedUserId ?? 'offline';
      _loading = false;
    });
  }

  Future<void> _login(String shopName, String email, String password) async {
    final response = await supabase.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    final userId = response.user!.id;
    final service = ShopAccountService(supabase);
    var resolvedName = await service.shopName(userId);
    if (resolvedName == null) {
      if (!mounted) return;
      var enteredName = '';
      final initialName = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Configurer votre première boutique'),
          content: TextField(
            onChanged: (value) => enteredName = value.trim(),
            decoration: const InputDecoration(labelText: 'Nom de la boutique'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                if (enteredName.isNotEmpty)
                  Navigator.pop(dialogContext, enteredName);
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      );
      if (initialName == null)
        throw StateError(
          'Configuration annulée. Reconnectez-vous pour terminer.',
        );
      resolvedName = await service.configure(userId, initialName);
    }
    shopName = resolvedName;
    final preferences = await SharedPreferences.getInstance();
    await activateShopPreferences(
      preferences,
      userId,
      legacyOwner: preferences.getString(_offlineUserIdKey),
    );
    await preferences.setString('shop_name', shopName);
    await preferences.setString('shop_name_$userId', shopName);
    await preferences.setBool(_offlineAccessKey, true);
    await preferences.setString(_offlineUserIdKey, userId);
    final isAdmin = await supabase.rpc('is_super_admin') as bool? ?? false;
    await preferences.setBool('is_super_admin_v1', isAdmin);
    await preferences.setBool(localStaffLoginRequiredKey, false);
    _localStaffSession = false;
    unawaited(_cacheLicenseVerification());
    unawaited(
      _logActivity(
        'login',
        'Connexion réussie',
        metadata: {'email': email},
        newSession: true,
      ),
    );
    if (!mounted) return;
    setState(() {
      _connected = true;
      _staffAccount = null;
      _offlineMode = false;
      _isSuperAdmin = isAdmin;
      _shopName = shopName;
      _storageUserId = response.user!.id;
    });
  }

  Future<void> _register(String shopName, String email, String password) async {
    final response = await supabase.auth.signUp(
      email: email.trim(),
      password: password,
      data: {'display_name': shopName.trim()},
    );
    if (response.session == null) {
      throw const AuthException(
        'Vérifiez votre adresse e-mail, puis connectez-vous. Si ce compte existe déjà, utilisez Se connecter.',
      );
    }
    await ShopAccountService(supabase).configure(response.user!.id, shopName);
    await _login('', email, password);
  }

  Future<void> _logout() async {
    if (_staffAccount != null) {
      if (mounted)
        setState(() {
          _connected = false;
          _staffAccount = null;
          _isSuperAdmin = false;
          _localLoginScreen = true;
        });
      return;
    }
    if (!_offlineMode)
      unawaited(_logActivity('logout', 'Déconnexion de la session'));
    try {
      await supabase.auth.signOut().timeout(const Duration(seconds: 3));
    } catch (_) {
      // La déconnexion locale doit rester possible sans connexion Internet.
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_offlineAccessKey);
    await preferences.remove(_offlineUserIdKey);
    await preferences.remove('is_super_admin_v1');
    await preferences.setBool(localStaffLoginRequiredKey, true);
    if (mounted) {
      setState(() {
        _connected = false;
        _offlineMode = false;
        _storageUserId = 'offline';
        _isSuperAdmin = false;
        _localLoginScreen = true;
      });
    }
  }

  Future<void> _loginLocal(String login, String password) async {
    final account = await LocalStaffStore().authenticate(login, password);
    final prefs = await SharedPreferences.getInstance();
    await activateShopPreferences(
      prefs,
      account.shopId,
      legacyOwner: prefs.getString(_offlineUserIdKey),
    );
    await prefs.setString('shop_name', account.shopName);
    if (!await prefs.setBool(localStaffLoginRequiredKey, true)) {
      throw StateError('Impossible d’ouvrir la session locale.');
    }
    _localStaffSession = true;
    if (!mounted) return;
    setState(() {
      _staffAccount = account;
      _storageUserId = account.shopId;
      _shopName = account.shopName;
      _offlineMode = true;
      _isSuperAdmin = false;
      _connected = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_connected)
      return LoginPage(
        onLogin: _login,
        onRegister: _register,
        onLocalLogin: _loginLocal,
        initialLocal: _localLoginScreen,
      );
    return AppShell(
      key: ValueKey('$_storageUserId/${_staffAccount?.id ?? "owner"}'),
      staffAccount: _staffAccount,
      shopName: _shopName,
      isSuperAdmin: _isSuperAdmin,
      storageUserId: _storageUserId,
      offlineMode: _offlineMode,
      enableCloudAnnouncements:
          !_offlineMode && supabase.auth.currentUser != null,
      onLogout: _logout,
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.onLogin,
    this.onRegister,
    this.onLocalLogin,
    this.initialLocal = false,
  });
  final Future<void> Function(String login, String password)? onLocalLogin;
  final bool initialLocal;
  final Future<void> Function(String shopName, String email, String password)?
  onRegister;
  final Future<void> Function(String shopName, String email, String password)
  onLogin;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _shop = TextEditingController();
  final _email = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;
  bool _hidden = true;
  bool _registering = false;
  late bool _local = widget.initialLocal;

  @override
  void dispose() {
    _shop.dispose();
    _email.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if ((!_local && _registering && _shop.text.trim().isEmpty) ||
        _email.text.trim().isEmpty ||
        _pin.text.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Renseignez vos identifiants et un mot de passe d’au moins 6 caractères.',
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      if (_local) {
        await widget.onLocalLogin!(_email.text.trim(), _pin.text);
      } else if (_registering) {
        await widget.onRegister!(
          _shop.text.trim(),
          _email.text.trim(),
          _pin.text,
        );
      } else {
        await widget.onLogin(_shop.text.trim(), _email.text.trim(), _pin.text);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is AuthException
                ? error.message
                : error is StateError
                ? error.message.toString()
                : 'Connexion impossible. Vérifiez les identifiants ou utilisez la connexion hors ligne.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(25),
                    child: Image.asset(
                      'assets/branding/moncommerce_logo.png',
                      width: 112,
                      height: 112,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                const Text(
                  'MonCommerce',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 31,
                    fontWeight: FontWeight.w900,
                    color: _dark,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Gérez. Suivez. Développez.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 35),
                if (widget.onLocalLogin != null) ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Propriétaire')),
                      ButtonSegment(
                        value: true,
                        label: Text('Utilisateur hors ligne'),
                      ),
                    ],
                    selected: {_local},
                    onSelectionChanged: _busy
                        ? null
                        : (values) => setState(() {
                            _local = values.single;
                            _pin.clear();
                          }),
                  ),
                  const SizedBox(height: 16),
                ],
                if (!_local && _registering)
                  TextField(
                    controller: _shop,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Nom de la boutique',
                      prefixIcon: Icon(Icons.store_outlined),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: _local
                        ? 'Identifiant de connexion'
                        : 'Adresse email',
                    prefixIcon: Icon(
                      _local ? Icons.badge_outlined : Icons.email_outlined,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pin,
                  obscureText: _hidden,
                  decoration: InputDecoration(
                    labelText: 'Mot de passe',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _hidden = !_hidden),
                      icon: Icon(
                        _hidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height: 54,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Text(
                      _busy
                          ? 'Connexion…'
                          : _local
                          ? 'Se connecter hors ligne'
                          : _registering
                          ? 'Créer mon compte et ma boutique'
                          : 'Accéder à ma boutique',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                if (!_local && widget.onRegister != null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _registering = !_registering),
                    child: Text(
                      _registering
                          ? 'J’ai déjà un compte : se connecter'
                          : 'Première utilisation : créer un compte',
                    ),
                  ),
                Text(
                  _local
                      ? 'Compte créé dans Utilisateurs sur cet appareil. Aucun accès Internet nécessaire.'
                      : 'Votre adresse e-mail retrouve la même boutique sur vos appareils. Internet est nécessaire pour synchroniser les données.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class Product {
  Product(
    this.name,
    this.price,
    this.stock,
    this.icon, {
    this.barcode = '',
    this.imagePath = '',
    this.imageUrl = '',
    this.syncedImagePath = '',
    this.cloudKey = '',
    this.purchasePrice,
  });
  String name;
  int price;
  int? purchasePrice;
  int stock;
  final IconData icon;
  String barcode;
  String imagePath;
  String imageUrl;
  String syncedImagePath;
  String cloudKey;

  Map<String, dynamic> toJson() => {
    'name': name,
    'price': price,
    'purchasePrice': purchasePrice,
    'stock': stock,
    'barcode': barcode,
    'imagePath': imagePath,
    'imageUrl': imageUrl,
    'syncedImagePath': syncedImagePath,
    'cloudKey': cloudKey,
  };

  factory Product.fromJson(Map<String, dynamic> json) => Product(
    json['name'] as String,
    json['price'] as int,
    json['stock'] as int,
    Icons.inventory_2_outlined,
    purchasePrice: (json['purchasePrice'] as num?)?.toInt(),
    barcode: json['barcode'] as String? ?? '',
    imagePath: json['imagePath'] as String? ?? '',
    imageUrl: json['imageUrl'] as String? ?? '',
    syncedImagePath: json['syncedImagePath'] as String? ?? '',
    cloudKey: json['cloudKey'] as String? ?? '',
  );
}

class SaleLine {
  SaleLine(this.product, this.quantity);
  final Product product;
  int quantity;
  int get total => product.price * quantity;
}

class SaleItemRecord {
  const SaleItemRecord(this.name, this.quantity, this.unitPrice);
  final String name;
  final int quantity;
  final int unitPrice;
  int get total => quantity * unitPrice;

  Map<String, dynamic> toJson() => {
    'name': name,
    'quantity': quantity,
    'unitPrice': unitPrice,
  };

  factory SaleItemRecord.fromJson(Map<String, dynamic> json) => SaleItemRecord(
    json['name'] as String,
    json['quantity'] as int,
    json['unitPrice'] as int,
  );
}

class Credit {
  Credit(this.customer, this.phone, this.amount, this.dueDate, {this.paid = 0});
  final String customer;
  final String phone;
  final int amount;
  int paid;
  final String dueDate;
  int get remaining => amount - paid;

  Map<String, dynamic> toJson() => {
    'customer': customer,
    'phone': phone,
    'amount': amount,
    'dueDate': dueDate,
    'paid': paid,
  };

  factory Credit.fromJson(Map<String, dynamic> json) => Credit(
    json['customer'] as String,
    json['phone'] as String,
    json['amount'] as int,
    json['dueDate'] as String,
    paid: json['paid'] as int? ?? 0,
  );
}

class SaleRecord {
  SaleRecord(
    this.product,
    this.amount,
    this.payment,
    this.time, {
    this.number = '',
    this.client = 'Client comptoir',
    this.date = '',
    this.items = const [],
    this.operatorId = '',
    this.operatorName = '',
    this.receiptMessage,
  });
  final String product;
  final String number;
  final int amount;
  final String payment;
  final String time;
  final String client;
  final String date;
  final List<SaleItemRecord> items;
  final String operatorId, operatorName;
  final String? receiptMessage;

  Map<String, dynamic> toJson() => {
    'product': product,
    'number': number,
    'amount': amount,
    'payment': payment,
    'time': time,
    'client': client,
    'date': date,
    'items': items.map((item) => item.toJson()).toList(),
    'operatorId': operatorId,
    'operatorName': operatorName,
    'receiptMessage': receiptMessage,
  };

  factory SaleRecord.fromJson(Map<String, dynamic> json) => SaleRecord(
    json['product'] as String,
    json['amount'] as int,
    json['payment'] as String,
    json['time'] as String,
    number:
        json['number'] as String? ??
        'V-${(json['date'] as String? ?? '').replaceAll('/', '')}-${json['time']}',
    client: json['client'] as String? ?? 'Client comptoir',
    date: json['date'] as String? ?? '',
    operatorId: json['operatorId'] as String? ?? '',
    operatorName: json['operatorName'] as String? ?? '',
    receiptMessage: json['receiptMessage'] as String?,
    items: ((json['items'] as List?) ?? const [])
        .map(
          (item) =>
              SaleItemRecord.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
  );
}

class ExpenseRecord {
  ExpenseRecord(this.nature, this.amount, this.createdAt);
  final String nature;
  final int amount;
  final String createdAt;
  Map<String, dynamic> toJson() => {
    'nature': nature,
    'amount': amount,
    'createdAt': createdAt,
  };
  factory ExpenseRecord.fromJson(Map<String, dynamic> json) => ExpenseRecord(
    json['nature'] as String,
    json['amount'] as int,
    json['createdAt'] as String,
  );
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.shopName,
    required this.isSuperAdmin,
    required this.onLogout,
    this.storageUserId = 'offline',
    this.offlineMode = false,
    this.enableCloudAnnouncements = false,
    this.staffAccount,
  });
  final String shopName;
  final bool isSuperAdmin;
  final String storageUserId;
  final bool offlineMode;
  final bool enableCloudAnnouncements;
  final LocalStaffAccount? staffAccount;
  final Future<void> Function() onLogout;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String get _storageKey => 'moncommerce_data_v2_${widget.storageUserId}';
  RealtimeChannel? _announcementChannel;
  RealtimeChannel? _ordersChannel;
  Timer? _presenceTimer;
  int _page = 0;
  int _salesCount = 0;
  int _revenue = 0;
  int _expenses = 0;
  final products = <Product>[];
  final credits = <Credit>[];
  final sales = <SaleRecord>[];
  final expenseRecords = <ExpenseRecord>[];

  @override
  void initState() {
    super.initState();
    _loadData();
    if (!widget.offlineMode && widget.staffAccount == null) {
      if (widget.enableCloudAnnouncements) _listenForAnnouncements();
      _listenForOnlineOrders();
      unawaited(_checkForUpdate());
      unawaited(_updatePresence(lastAction: 'app_active'));
      _presenceTimer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => unawaited(_updatePresence(lastAction: 'heartbeat')),
      );
    }
  }

  void _listenForAnnouncements() {
    _announcementChannel = supabase
        .channel('app-announcements-${supabase.auth.currentUser?.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'app_announcements',
          callback: (payload) {
            if (!mounted) return;
            final row = payload.newRecord;
            final isUpdate = row['kind'] == 'update';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 10),
                content: Text(
                  '${isUpdate ? 'Mise à jour' : 'Notification'} : ${row['title'] ?? ''}',
                ),
                action: SnackBarAction(
                  label: 'Voir',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const AnnouncementsPage(),
                    ),
                  ),
                ),
              ),
            );
          },
        )
        .subscribe();
  }

  Future<void> _checkForUpdate() async {
    try {
      final rows = await supabase
          .from('app_announcements')
          .select('title, body, version, download_url, is_mandatory')
          .eq('kind', 'update')
          .order('created_at', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 6));
      if (rows.isEmpty || !mounted) return;
      final update = Map<String, dynamic>.from(rows.first);
      final version = update['version']?.toString() ?? '';
      final downloadUrl = update['download_url']?.toString() ?? '';
      if (version.isEmpty ||
          downloadUrl.isEmpty ||
          !_isNewerVersion(version, _appVersion)) {
        return;
      }
      final mandatory = update['is_mandatory'] == true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          barrierDismissible: !mandatory,
          builder: (dialogContext) => AlertDialog(
            title: Text('Mise à jour $version disponible'),
            content: Text(
              '${update['body'] ?? 'Une nouvelle version de MonCommerce est disponible.'}${mandatory ? '\n\nCette mise à jour est obligatoire.' : ''}',
            ),
            actions: [
              if (!mandatory)
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Plus tard'),
                ),
              UpdateDownloadButton(downloadUrl: downloadUrl, version: version),
            ],
          ),
        );
      });
    } catch (_) {}
  }

  void _listenForOnlineOrders() {
    if (!_supabaseReady) return;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;
    _ordersChannel = supabase
        .channel('store-orders-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'store_orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id',
            value: userId,
          ),
          callback: (payload) {
            if (!mounted) return;
            final row = payload.newRecord;
            final number = row['order_number']?.toString() ?? 'Nouvelle';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 12),
                content: Text(
                  '$number • ${row['customer_name'] ?? 'Client'} • ${money((row['total'] as num?)?.toInt() ?? 0)} FCFA',
                ),
                action: SnackBarAction(
                  label: 'OUVRIR',
                  onPressed: _openOnlineOrders,
                ),
              ),
            );
            unawaited(
              _localNotifications.show(
                id: number.hashCode,
                title: 'Nouvelle commande $number',
                body:
                    '${row['customer_name'] ?? 'Client'} • ${money((row['total'] as num?)?.toInt() ?? 0)} FCFA',
                notificationDetails: const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'moncommerce_alerts',
                    'Notifications MonCommerce',
                    channelDescription:
                        'Annonces et mises à jour envoyées par MonCommerce',
                    importance: Importance.max,
                    priority: Priority.high,
                  ),
                ),
              ),
            );
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _shopSyncTimer?.cancel();
    final channel = _announcementChannel;
    if (channel != null) supabase.removeChannel(channel);
    final ordersChannel = _ordersChannel;
    if (ordersChannel != null) supabase.removeChannel(ordersChannel);
    super.dispose();
  }

  bool _dataReady = false;
  SharedPreferences? _shopPreferences;
  bool _syncBusy = false;
  bool _syncConflict = false;
  String? _lastPublishedCatalog;
  bool _hasLocalData = false;
  int _localGeneration = 0;
  Timer? _shopSyncTimer;
  String _syncStatus = 'Synchronisation en attente';

  Map<String, dynamic> _shopData() => {
    'revenue': _revenue,
    'expenses': _expenses,
    'salesCount': _salesCount,
    'products': products.map((p) => p.toJson()).toList(),
    'credits': credits.map((p) => p.toJson()).toList(),
    'sales': sales.map((p) => p.toJson()).toList(),
    'expenseRecords': expenseRecords.map((p) => p.toJson()).toList(),
    'settings': _shopPreferences == null
        ? <String, dynamic>{}
        : readSharedShopPreferences(_shopPreferences!),
  };

  void _applyShopData(Map<String, dynamic> data) {
    setState(() {
      _revenue = data['revenue'] as int;
      _expenses = data['expenses'] as int;
      _salesCount = data['salesCount'] as int;
      products
        ..clear()
        ..addAll(
          (data['products'] as List).map(
            (item) => Product.fromJson(item as Map<String, dynamic>),
          ),
        );
      credits
        ..clear()
        ..addAll(
          (data['credits'] as List).map(
            (item) => Credit.fromJson(item as Map<String, dynamic>),
          ),
        );
      sales
        ..clear()
        ..addAll(
          (data['sales'] as List).map(
            (item) => SaleRecord.fromJson(item as Map<String, dynamic>),
          ),
        );
      expenseRecords
        ..clear()
        ..addAll(
          ((data['expenseRecords'] as List?) ?? const []).map(
            (item) => ExpenseRecord.fromJson(item as Map<String, dynamic>),
          ),
        );
    });
  }

  Future<void> _loadData() async {
    final preferences = await SharedPreferences.getInstance();
    _shopPreferences = preferences;
    final stored = preferences.getString(_storageKey);
    if (!mounted) return;
    if (stored != null) {
      try {
        _applyShopData(Map<String, dynamic>.from(jsonDecode(stored) as Map));
        _hasLocalData = true;
      } catch (_) {
        setState(
          () => _syncStatus =
              'Données locales illisibles : synchronisation suspendue',
        );
        return;
      }
    }
    setState(() => _dataReady = true);
    await _synchronizeShop();
    if (!mounted) return;
    _shopSyncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_synchronizeShop()),
    );
  }

  Future<void> _synchronizeShop() async {
    if (!_supabaseReady ||
        !_dataReady ||
        _syncBusy ||
        widget.staffAccount != null ||
        supabase.auth.currentUser?.id != widget.storageUserId)
      return;
    // Sending local sales is allowed while the till is open. Applying a different
    // remote snapshot waits until the editor/sale route closes.
    _syncBusy = true;
    final generation = _localGeneration;
    try {
      final preferences = await SharedPreferences.getInstance();
      final remote = SupabaseShopSyncRemote(supabase, widget.storageUserId);
      final sync = ShopSync(widget.storageUserId, remote, preferences);
      var local = _shopData();
      final capturedLocal = canonicalShopData(local);
      if (!_hasLocalData && await remote.read() == null) {
        final rows = await supabase
            .from('store_products')
            .select('product_key,name,price,stock,image_url')
            .eq('shop_id', widget.storageUserId)
            .eq('active', true);
        local = {
          ...local,
          'products': [
            for (final row in rows)
              {
                'cloudKey': row['product_key'],
                'name': row['name'],
                'price': row['price'],
                'stock': row['stock'],
                'imageUrl': row['image_url'] ?? '',
              },
          ],
        };
      }
      final result = await sync.synchronize(
        local,
        hasLocalData: _hasLocalData,
        remember: false,
      );
      if (!mounted) return;
      if (generation == _localGeneration &&
          canonicalShopData(_shopData()) == capturedLocal &&
          (ModalRoute.of(context)?.isCurrent == true ||
              canonicalShopData(result) == capturedLocal)) {
        if (canonicalShopData(result) != canonicalShopData(_shopData())) {
          if (_hasLocalData)
            await preferences.setString(
              '${_storageKey}_before_sync',
              jsonEncode(_shopData()),
            );
          if (!mounted ||
              generation != _localGeneration ||
              ModalRoute.of(context)?.isCurrent != true)
            return;
          _applyShopData(result);
        }
        if (result['settings'] is Map) {
          await writeSharedShopPreferences(
            preferences,
            Map<String, dynamic>.from(result['settings'] as Map),
          );
        }
        if (!await preferences.setString(_storageKey, jsonEncode(_shopData())))
          throw StateError('Sauvegarde locale impossible.');
        await sync.commit(result);
        _hasLocalData = true;
        await _syncStorefrontProducts();
        if (generation == _localGeneration &&
            mounted &&
            ModalRoute.of(context)?.isCurrent == true) {
          final withImages = _shopData();
          if (canonicalShopData(withImages) != canonicalShopData(result)) {
            await sync.synchronize(
              withImages,
              hasLocalData: true,
              remember: false,
            );
            await sync.commit(withImages);
          }
        }
        if (mounted)
          setState(() {
            _syncStatus = 'Boutique synchronisée';
            _syncConflict = false;
          });
      } else {
        setState(
          () => _syncStatus = 'Modifications locales en attente d’envoi',
        );
      }
    } on ShopSyncConflict {
      if (mounted)
        setState(() {
          _syncConflict = true;
          _syncStatus =
              'Conflit : modifications sur deux appareils. Données locales conservées.';
        });
    } catch (_) {
      if (mounted)
        setState(
          () => _syncStatus =
              'Non synchronisé : vérifiez Internet et la configuration du serveur. Données conservées sur cet appareil.',
        );
    } finally {
      _syncBusy = false;
    }
  }

  Future<void> _resolveShopConflict() async {
    if (_syncBusy) return;
    setState(() => _syncBusy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final remote = SupabaseShopSyncRemote(supabase, widget.storageUserId);
      final cloud = await remote.read();
      if (cloud == null || !mounted) return;
      final local = _shopData();
      final generation = _localGeneration;
      String summary(Map<String, dynamic> data) =>
          '${(data['products'] as List? ?? []).length} produits • ${(data['sales'] as List? ?? []).length} ventes • ${(data['expenseRecords'] as List? ?? []).length} dépenses';
      final choice = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Choisir la version de la boutique'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Cet appareil : ${summary(local)}'),
                  const SizedBox(height: 12),
                  Text('Version synchronisée : ${summary(cloud.data)}'),
                  const SizedBox(height: 16),
                  const Text(
                    'Les modifications des deux versions ne seront pas fusionnées. La version choisie remplacera l’autre. Les deux copies seront sauvegardées sur cet appareil avant le remplacement.',
                  ),
                  TextButton(
                    onPressed: () async {
                      await FilePicker.saveFile(
                        dialogTitle: 'Sauvegarder les deux versions',
                        fileName: 'sauvegarde-conflit-boutique.json',
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                        bytes: Uint8List.fromList(
                          utf8.encode(
                            jsonEncode({'local': local, 'cloud': cloud.data}),
                          ),
                        ),
                      );
                    },
                    child: const Text(
                      'Exporter les deux copies avant de choisir',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'cloud'),
              child: const Text('Récupérer la version synchronisée'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'local'),
              child: const Text('Garder cet appareil'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted || generation != _localGeneration) return;
      if (!await prefs.setString(
        'shop_conflict_backup_${widget.storageUserId}_${DateTime.now().millisecondsSinceEpoch}',
        jsonEncode({'local': local, 'cloud': cloud.data}),
      ))
        throw StateError('Sauvegarde impossible');
      final chosen = choice == 'local' ? local : cloud.data;
      final revision = choice == 'local'
          ? await remote.write(local, cloud.revision)
          : cloud.revision;
      if (!mounted) return;
      if (choice == 'cloud') {
        _applyShopData(chosen);
        if (chosen['settings'] is Map)
          await writeSharedShopPreferences(
            prefs,
            Map<String, dynamic>.from(chosen['settings'] as Map),
          );
      }
      if (!await prefs.setString(_storageKey, jsonEncode(_shopData())))
        throw StateError('Enregistrement local impossible');
      final sync = ShopSync(widget.storageUserId, remote, prefs)
        ..synchronizedRevision = revision;
      await sync.commit(chosen);
      if (mounted)
        setState(() {
          _syncConflict = false;
          _syncStatus = 'Version choisie enregistrée';
        });
    } catch (_) {
      if (mounted)
        setState(
          () => _syncStatus =
              'Résolution interrompue. Les copies sont conservées ; réessayez la synchronisation.',
        );
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<void> _saveData() async {
    _localGeneration++;
    for (var i = 0; i < products.length; i++) {
      if (products[i].cloudKey.isEmpty)
        products[i].cloudKey = '${DateTime.now().microsecondsSinceEpoch}-$i';
    }
    final payload = jsonEncode(_shopData());
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(_storageKey, payload);
    if (!saved) throw StateError('Enregistrement local impossible.');
    _hasLocalData = true;
    unawaited(_synchronizeShop());
  }

  Future<void> _syncStorefrontProducts() async {
    if (!_supabaseReady || widget.offlineMode || widget.staffAccount != null)
      return;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null || userId != widget.storageUserId) return;
    if (_lastPublishedCatalog ==
        canonicalShopData(products.map((p) => p.toJson()).toList()))
      return;
    try {
      var generatedKey = false;
      for (var index = 0; index < products.length; index++) {
        final product = products[index];
        if (product.cloudKey.isEmpty) {
          product.cloudKey =
              '${DateTime.now().microsecondsSinceEpoch}-$index-${product.name.hashCode.abs()}';
          generatedKey = true;
        }
        final localImage = File(product.imagePath);
        if (product.imagePath.isNotEmpty &&
            localImage.existsSync() &&
            (product.imageUrl.isEmpty ||
                product.syncedImagePath != product.imagePath)) {
          final rawExtension = product.imagePath.contains('.')
              ? product.imagePath.split('.').last.toLowerCase()
              : 'jpg';
          final extension =
              const ['jpg', 'jpeg', 'png', 'webp'].contains(rawExtension)
              ? rawExtension
              : 'jpg';
          final contentType = extension == 'png'
              ? 'image/png'
              : extension == 'webp'
              ? 'image/webp'
              : 'image/jpeg';
          final objectPath = '$userId/${product.cloudKey}.$extension';
          await supabase.storage
              .from('product-images')
              .upload(
                objectPath,
                localImage,
                fileOptions: FileOptions(
                  upsert: true,
                  contentType: contentType,
                ),
              );
          product.imageUrl = supabase.storage
              .from('product-images')
              .getPublicUrl(objectPath);
          product.syncedImagePath = product.imagePath;
          generatedKey = true;
        }
      }
      final keys = products.map((product) => product.cloudKey).toList();
      if (products.isNotEmpty) {
        await supabase
            .from('store_products')
            .upsert(
              products
                  .map(
                    (product) => {
                      'shop_id': userId,
                      'product_key': product.cloudKey,
                      'name': product.name,
                      'price': product.price,
                      'stock': product.stock,
                      'image_url': product.imageUrl,
                      'active': true,
                    },
                  )
                  .toList(),
              onConflict: 'shop_id,product_key',
            );
      }
      final existing = await supabase
          .from('store_products')
          .select('product_key')
          .eq('shop_id', userId);
      for (final row in existing) {
        final key = row['product_key']?.toString() ?? '';
        if (!keys.contains(key)) {
          await supabase
              .from('store_products')
              .update({'active': false})
              .eq('shop_id', userId)
              .eq('product_key', key);
        }
      }
      if (generatedKey) {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(
          _storageKey,
          jsonEncode({
            'revenue': _revenue,
            'expenses': _expenses,
            'salesCount': _salesCount,
            'products': products.map((item) => item.toJson()).toList(),
            'credits': credits.map((item) => item.toJson()).toList(),
            'sales': sales.map((item) => item.toJson()).toList(),
            'expenseRecords': expenseRecords
                .map((item) => item.toJson())
                .toList(),
          }),
        );
      }
      _lastPublishedCatalog = canonicalShopData(
        products.map((p) => p.toJson()).toList(),
      );
    } catch (error) {
      unawaited(
        _logActivity(
          'storefront_sync_error',
          'Échec de synchronisation du catalogue web',
          severity: 'warning',
          metadata: {'error': error.toString()},
        ),
      );
    }
  }

  void _openOnlineOrders() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => OnlineOrdersPage(
          products: products,
          onValidated: _validateOnlineOrder,
        ),
      ),
    );
  }

  Future<void> _validateOnlineOrder(Map<String, dynamic> order) async {
    final rawItems = (order['items'] as List?) ?? const [];
    final items = rawItems
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final total = (order['total'] as num?)?.toInt() ?? 0;
    final now = DateTime.now();
    setState(() {
      for (final item in items) {
        final productName = item['name']?.toString() ?? '';
        final quantity = (item['quantity'] as num?)?.toInt() ?? 0;
        final matches = products.where(
          (product) => product.name == productName,
        );
        if (matches.isNotEmpty) {
          matches.first.stock = (matches.first.stock - quantity).clamp(
            0,
            1 << 31,
          );
        }
      }
      _salesCount++;
      _revenue += total;
      sales.insert(
        0,
        SaleRecord(
          items.map((item) => item['name']).join(', '),
          total,
          order['payment_method']?.toString() ?? 'Commande web',
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
          number:
              'V-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${_salesCount.toString().padLeft(5, '0')}',
          client: order['customer_name']?.toString() ?? 'Client web',
          date:
              '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
          items: items
              .map(
                (item) => SaleItemRecord(
                  item['name']?.toString() ?? 'Article',
                  (item['quantity'] as num?)?.toInt() ?? 0,
                  (item['unit_price'] as num?)?.toInt() ?? 0,
                ),
              )
              .toList(),
        ),
      );
    });
    await _saveData();
  }

  void _openSale() {
    if (products.isEmpty) {
      _toast('Ajoutez d’abord au moins un produit.');
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          body: SafeArea(
            child: SaleSheet(
              products: products,
              onValidated: (lines, payment, client) async {
                final receiptMessage =
                    (await SharedPreferences.getInstance()).getString(
                      receiptFooterKey,
                    ) ??
                    defaultReceiptFooter;
                final staff = widget.staffAccount;
                if (staff != null) {
                  final latest = (await LocalStaffStore().forShop(
                    staff.shopId,
                  )).where((a) => a.id == staff.id).firstOrNull;
                  if (latest == null ||
                      !latest.active ||
                      latest.role != staff.role) {
                    throw StateError(
                      'Session utilisateur expirée. Reconnectez-vous.',
                    );
                  }
                }
                final total = lines.fold(0, (sum, line) => sum + line.total);
                setState(() {
                  for (final line in lines) {
                    line.product.stock -= line.quantity;
                  }
                  _salesCount++;
                  _revenue += total;
                  final now = DateTime.now();
                  sales.insert(
                    0,
                    SaleRecord(
                      lines
                          .map(
                            (line) => line.quantity > 1
                                ? '${line.product.name} × ${line.quantity}'
                                : line.product.name,
                          )
                          .join(', '),
                      total,
                      payment,
                      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                      operatorId: widget.staffAccount?.id ?? '',
                      operatorName: widget.staffAccount?.name ?? '',
                      receiptMessage: receiptMessage,
                      number:
                          'V-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${_salesCount.toString().padLeft(5, '0')}',
                      client: client.isEmpty ? 'Client comptoir' : client,
                      date:
                          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
                      items: lines
                          .map(
                            (line) => SaleItemRecord(
                              line.product.name,
                              line.quantity,
                              line.product.price,
                            ),
                          )
                          .toList(),
                    ),
                  );
                });
                final savedSale = sales.first;
                try {
                  await _finishSale(savedSale);
                } catch (_) {
                  if (mounted) {
                    setState(() {
                      sales.remove(savedSale);
                      _salesCount--;
                      _revenue -= total;
                      for (final line in lines) {
                        line.product.stock += line.quantity;
                      }
                    });
                  }
                  rethrow;
                }
                unawaited(
                  _logActivity(
                    'sale_created',
                    'Vente de ${money(total)} FCFA enregistrée',
                    metadata: {
                      'amount': total,
                      'payment': payment,
                      'client': client.isEmpty ? 'Client comptoir' : client,
                      'items_count': lines.length,
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _toast(String message, {bool aboveSaleControls = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: aboveSaleControls
            ? const EdgeInsets.fromLTRB(18, 0, 18, 100)
            : null,
      ),
    );
  }

  Future<void> _finishSale(SaleRecord sale) async {
    try {
      await _saveData();
    } catch (_) {
      throw StateError(
        'Échec de l’enregistrement local. Impression non lancée.',
      );
    }
    try {
      final sent = await ReceiptPrinting.afterSale(
        name: '${sale.number}.pdf',
        format: saleReceiptFormat(sale),
        buildReceipt: () => buildSaleReceipt(sale),
      );
      if (mounted) {
        _toast(
          sent
              ? 'Vente enregistrée • Ticket envoyé à l’imprimante'
              : 'Vente enregistrée • ${sale.payment}',
          aboveSaleControls: true,
        );
      }
    } catch (error) {
      if (!mounted) return;
      final detail = error is StateError
          ? error.message
          : 'Vérifiez l’imprimante.';
      _toast(
        'Vente enregistrée. Impression non confirmée : $detail Réimprimez depuis Ventes si nécessaire.',
        aboveSaleControls: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.staffAccount != null)
      return _staffWorkspace(widget.staffAccount!);
    final pages = [
      DashboardPage(
        shopName: widget.shopName,
        revenue: _revenue,
        expenses: _expenses,
        salesCount: _salesCount,
        products: products,
        credits: credits,
        onSale: _openSale,
        onNavigate: (index) => setState(() => _page = index),
      ),
      SalesPage(sales: sales, onSale: _openSale),
      ProductsPage(
        products: products,
        onChanged: () {
          setState(() {});
          _saveData();
          unawaited(
            _logActivity(
              'inventory_updated',
              'Catalogue ou stock modifié',
              metadata: {'products_count': products.length},
            ),
          );
        },
      ),
      MorePage(
        storageUserId: widget.storageUserId,
        shopName: widget.shopName,
        isSuperAdmin: widget.isSuperAdmin,
        revenue: _revenue,
        salesCount: _salesCount,
        expenses: _expenses,
        expenseRecords: expenseRecords,
        credits: credits,
        sales: sales,
        products: products,
        onOpenOnlineOrders: _openOnlineOrders,
        onPublishStorefront: _syncStorefrontProducts,
        onExpense: (record) {
          setState(() {
            expenseRecords.insert(0, record);
            _expenses += record.amount;
          });
          _saveData();
          unawaited(
            _logActivity(
              'expense_created',
              'Dépense ${record.nature} enregistrée',
              metadata: {'nature': record.nature, 'amount': record.amount},
            ),
          );
        },
        onCredit: (credit) {
          setState(() => credits.add(credit));
          _saveData();
          unawaited(
            _logActivity(
              'customer_credit_created',
              'Crédit client enregistré',
              metadata: {'customer': credit.customer, 'amount': credit.amount},
            ),
          );
        },
        onLogout: widget.onLogout,
        onDataChanged: _saveData,
      ),
    ];
    final isDesktop = MediaQuery.sizeOf(context).width >= 900;
    final navigation = const [
      NavigationRailDestination(
        icon: Icon(Icons.grid_view_rounded),
        label: Text('Accueil'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.receipt_long_outlined),
        label: Text('Ventes'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.inventory_2_outlined),
        label: Text('Produits'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.apps_rounded),
        label: Text('Plus'),
      ),
    ];
    final content = IndexedStack(index: _page, children: pages);
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (isDesktop)
              NavigationRail(
                selectedIndex: _page,
                extended: MediaQuery.sizeOf(context).width >= 1180,
                minExtendedWidth: 210,
                labelType: MediaQuery.sizeOf(context).width >= 1180
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.storefront_rounded,
                        color: _green,
                        size: 32,
                      ),
                      const SizedBox(height: 14),
                      if (_page == 1)
                        FilledButton.icon(
                          onPressed: _openSale,
                          icon: const Icon(Icons.add),
                          label: const Text('Nouvelle vente'),
                        ),
                    ],
                  ),
                ),
                onDestinationSelected: (value) => setState(() => _page = value),
                destinations: navigation,
              ),
            if (isDesktop) const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  if (_supabaseReady && widget.staffAccount == null)
                    Material(
                      color: const Color(0xFFF1F5F2),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.cloud_outlined, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _syncStatus,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Synchroniser maintenant',
                              onPressed: _syncBusy ? null : _synchronizeShop,
                              icon: const Icon(Icons.sync),
                            ),
                            if (_syncConflict)
                              TextButton(
                                onPressed: _syncBusy
                                    ? null
                                    : _resolveShopConflict,
                                child: const Text('Résoudre'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (widget.offlineMode)
                    Container(
                      width: double.infinity,
                      color: const Color(0xFFFFF3D6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 9,
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.cloud_off_outlined,
                            color: Color(0xFF9A6510),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Mode hors ligne : vos données restent disponibles localement.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: isDesktop
                        ? Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1500),
                              child: content,
                            ),
                          )
                        : content,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: isDesktop
          ? null
          : NavigationBar(
              selectedIndex: _page,
              indicatorColor: _green.withValues(alpha: .14),
              onDestinationSelected: (value) => setState(() => _page = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.grid_view_rounded),
                  label: 'Accueil',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  label: 'Ventes',
                ),
                NavigationDestination(
                  icon: Icon(Icons.inventory_2_outlined),
                  label: 'Produits',
                ),
                NavigationDestination(
                  icon: Icon(Icons.apps_rounded),
                  label: 'Plus',
                ),
              ],
            ),
      floatingActionButton: _page == 1 && !isDesktop
          ? FloatingActionButton.extended(
              onPressed: _openSale,
              backgroundColor: _green,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Nouvelle vente'),
            )
          : null,
    );
  }

  Widget _staffWorkspace(LocalStaffAccount staff) {
    final pages = <Widget>[
      SalesPage(sales: sales, onSale: _openSale),
      if (staff.canManageStock)
        ProductsPage(
          products: products,
          onChanged: () {
            setState(() {});
            _saveData();
          },
        ),
      if (staff.canManageStock)
        ReportsPage(
          revenue: _revenue,
          expenses: _expenses,
          salesCount: _salesCount,
          creditTotal: credits.fold(0, (sum, c) => sum + c.remaining),
          sales: sales,
          products: products,
          expenseRecords: expenseRecords,
        ),
      if (staff.canManageUsers)
        LocalStaffPage(
          shopId: widget.storageUserId,
          shopName: widget.shopName,
          actingAccountId: staff.id,
        ),
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '${staff.name} • ${staff.role}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text(
            'Boutique : ${widget.shopName}\nSession locale • sans connexion Internet',
          ),
          const SizedBox(height: 20),
          const ReceiptPrintSettingsCard(),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
            label: const Text('Déconnexion / changer d’utilisateur'),
          ),
        ],
      ),
    ];
    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.receipt_long),
        label: 'Ventes',
      ),
      if (staff.canManageStock)
        const NavigationDestination(
          icon: Icon(Icons.inventory_2_outlined),
          label: 'Produits',
        ),
      if (staff.canManageStock)
        const NavigationDestination(
          icon: Icon(Icons.bar_chart),
          label: 'Rapports',
        ),
      if (staff.canManageUsers)
        const NavigationDestination(
          icon: Icon(Icons.people),
          label: 'Utilisateurs',
        ),
      const NavigationDestination(
        icon: Icon(Icons.badge_outlined),
        label: 'Session',
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.shopName} • ${staff.name} (${staff.role})'),
        actions: [
          IconButton(
            tooltip: 'Déconnexion',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: IndexedStack(index: _page, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        destinations: destinations,
        onDestinationSelected: (value) => setState(() => _page = value),
      ),
      floatingActionButton: _page == 0
          ? FloatingActionButton.extended(
              onPressed: _openSale,
              icon: const Icon(Icons.add),
              label: const Text('Nouvelle vente'),
            )
          : null,
    );
  }
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.revenue,
    required this.shopName,
    required this.expenses,
    required this.salesCount,
    required this.products,
    required this.credits,
    required this.onSale,
    required this.onNavigate,
  });
  final int revenue, expenses, salesCount;
  final String shopName;
  final List<Product> products;
  final List<Credit> credits;
  final VoidCallback onSale;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final lowStock = products.where((p) => p.stock <= 6).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _green,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(Icons.storefront_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Bonjour, $shopName',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                  const Text(
                    'Mardi 4 août',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Notifications'),
                  content: Text(
                    '$lowStock produit(s) en stock faible et ${credits.length} crédit(s) à suivre.',
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Compris'),
                    ),
                  ],
                ),
              ),
              icon: const Badge(child: Icon(Icons.notifications_none_rounded)),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [_dark, _green],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CHIFFRE D’AFFAIRES DU JOUR',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  letterSpacing: .7,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${money(revenue)} FCFA',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 29,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _miniMetric(
                    Icons.shopping_bag_outlined,
                    '$salesCount ventes',
                  ),
                  const SizedBox(width: 22),
                  _miniMetric(Icons.trending_up, '+12,5 %'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: MetricCard(
                label: 'Bénéfice estimé',
                value: '${money(revenue - expenses)} F',
                icon: Icons.account_balance_wallet_outlined,
                color: _green,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MetricCard(
                label: 'Dépenses',
                value: '${money(expenses)} F',
                icon: Icons.arrow_outward_rounded,
                color: const Color(0xFFD56A4D),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const SectionTitle('Actions rapides'),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            QuickAction(
              'Vendre',
              Icons.add_shopping_cart_rounded,
              _green,
              onSale,
            ),
            QuickAction(
              'Produits',
              Icons.inventory_2_outlined,
              const Color(0xFF4776B7),
              () => onNavigate(2),
            ),
            QuickAction(
              'Dépense',
              Icons.payments_outlined,
              const Color(0xFFD56A4D),
              () => onNavigate(3),
            ),
            QuickAction(
              'Crédits',
              Icons.people_outline_rounded,
              _orange,
              () => onNavigate(3),
            ),
          ],
        ),
        const SizedBox(height: 26),
        StockValueCard(
          value: StockValue(
            products.map(
              (p) => (
                stock: p.stock,
                price: p.price,
                purchasePrice: p.purchasePrice,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SectionTitle('À surveiller', trailing: '$lowStock stock(s) faible(s)'),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFFE9DF),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFD56A4D),
                  ),
                ),
                title: Text(
                  '$lowStock produits bientôt épuisés',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text('Vérifiez votre stock'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onNavigate(2),
              ),
              const Divider(height: 1, indent: 72),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFFF3D6),
                  child: Icon(Icons.schedule, color: _orange),
                ),
                title: Text(
                  '${credits.length} crédits à encaisser',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${money(credits.fold(0, (sum, item) => sum + item.remaining))} FCFA en attente',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onNavigate(3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _miniMetric(IconData icon, String text) => Row(
  children: [
    Icon(icon, size: 17, color: Colors.white70),
    const SizedBox(width: 6),
    Text(
      text,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
    ),
  ],
);

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label, value;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 14),
          Text(
            value,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class QuickAction extends StatelessWidget {
  const QuickAction(this.label, this.icon, this.color, this.onTap, {super.key});
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final String? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: _dark,
          ),
        ),
      ),
      if (trailing != null)
        Text(
          trailing!,
          style: const TextStyle(
            color: _green,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
    ],
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, this.subtitle, {super.key});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 22, 18, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w900,
            color: _dark,
          ),
        ),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: Colors.black54)),
      ],
    ),
  );
}

PdfPageFormat saleReceiptFormat(SaleRecord sale, {String? footerMessage}) =>
    PdfPageFormat(
      80 * PdfPageFormat.mm,
      (122 +
              (footerMessage ?? sale.receiptMessage ?? defaultReceiptFooter)
                      .split('\n')
                      .fold<int>(
                        0,
                        (count, line) =>
                            count + (line.length / 36).ceil().clamp(1, 100),
                      ) *
                  4 +
              (sale.items.isEmpty
                      ? sale.product.split(',').length
                      : sale.items.length) *
                  9) *
          PdfPageFormat.mm,
    );

Future<Uint8List> buildSaleReceipt(SaleRecord sale) async {
  final prefs = await SharedPreferences.getInstance();
  final footer =
      sale.receiptMessage ??
      prefs.getString(receiptFooterKey) ??
      defaultReceiptFooter;
  final shop = prefs.getString('shop_name') ?? 'MONCOMMERCE';
  final phone = prefs.getString('shop_phone') ?? '';
  final address = prefs.getString('shop_address') ?? '';
  final items = sale.items.isEmpty
      ? sale.product.split(',').map((rawItem) {
          final label = rawItem.trim();
          final quantityMatch = RegExp(
            r'\s*[×x]\s*(\d+)\s*$',
          ).firstMatch(label);
          final quantity = quantityMatch == null
              ? 1
              : int.tryParse(quantityMatch.group(1)!) ?? 1;
          final name = quantityMatch == null
              ? label
              : label.substring(0, quantityMatch.start).trim();
          return SaleItemRecord(
            name,
            quantity,
            sale.product.contains(',') ? 0 : sale.amount ~/ quantity,
          );
        }).toList()
      : sale.items;
  final document = pw.Document();
  document.addPage(
    pw.Page(
      pageFormat: saleReceiptFormat(sale, footerMessage: footer),
      margin: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Center(
            child: pw.Text(
              shop.toUpperCase(),
              style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
            ),
          ),
          if (address.isNotEmpty)
            pw.Center(
              child: pw.Text(address, style: const pw.TextStyle(fontSize: 8)),
            ),
          if (phone.isNotEmpty)
            pw.Center(
              child: pw.Text(
                'Tel : $phone',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          pw.SizedBox(height: 5),
          pw.Center(
            child: pw.Text(
              'TICKET DE VENTE',
              style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            '================================',
            style: const pw.TextStyle(fontSize: 7),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                sale.number.isEmpty ? 'VENTE' : sale.number,
                style: const pw.TextStyle(fontSize: 8),
              ),
              pw.Text(
                '${sale.date} ${sale.time}',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ],
          ),
          pw.Text(
            'Client : ${sale.client}',
            style: const pw.TextStyle(fontSize: 8),
          ),
          pw.SizedBox(height: 4),
          pw.Row(
            children: [
              pw.Expanded(
                child: pw.Text(
                  'PRODUIT',
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(
                width: 46,
                child: pw.Text(
                  'P. UNIT.',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(
                width: 26,
                child: pw.Text(
                  'QTE',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(
                width: 48,
                child: pw.Text(
                  'MONTANT',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          pw.Text(
            '--------------------------------',
            style: const pw.TextStyle(fontSize: 7),
          ),
          ...items.map(
            (item) => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      item.name,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  ),
                  pw.SizedBox(
                    width: 46,
                    child: pw.Text(
                      item.unitPrice > 0 ? money(item.unitPrice) : '-',
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                  pw.SizedBox(
                    width: 26,
                    child: pw.Text(
                      '${item.quantity}',
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                  pw.SizedBox(
                    width: 48,
                    child: pw.Text(
                      item.unitPrice > 0 ? money(item.total) : '-',
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                ],
              ),
            ),
          ),
          pw.Text(
            '================================',
            style: const pw.TextStyle(fontSize: 7),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'TOTAL',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.Text(
                '${money(sale.amount)} FCFA',
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Paiement', style: const pw.TextStyle(fontSize: 8)),
              pw.Text(sale.payment, style: const pw.TextStyle(fontSize: 8)),
            ],
          ),
          pw.SizedBox(height: 7),
          if (footer.isNotEmpty)
            pw.Center(
              child: pw.Text(
                footer,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          pw.SizedBox(height: 5),
          pw.Center(
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data:
                  'MonCommerce|${sale.number}|${sale.date} ${sale.time}|${sale.amount} FCFA',
              width: 45,
              height: 45,
            ),
          ),
        ],
      ),
    ),
  );
  return document.save();
}

class SalesPage extends StatefulWidget {
  const SalesPage({super.key, required this.sales, required this.onSale});
  final List<SaleRecord> sales;
  final VoidCallback onSale;

  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final visibleSales = widget.sales.where((sale) {
      return query.isEmpty ||
          sale.number.toLowerCase().contains(query) ||
          sale.product.toLowerCase().contains(query) ||
          sale.client.toLowerCase().contains(query);
    }).toList()..sort((a, b) => b.number.compareTo(a.number));
    return Column(
      children: [
        const PageHeader('Ventes', 'Historique des opérations du jour'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Rechercher une vente',
              suffixIcon: IconButton(
                onPressed: () {},
                icon: const Icon(Icons.tune),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 90),
            itemCount: visibleSales.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final sale = visibleSales[index];
              return Card(
                child: ListTile(
                  onTap: () => _saleActions(context, sale),
                  contentPadding: const EdgeInsets.all(14),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE1F1EA),
                    child: Icon(Icons.receipt_long_outlined, color: _green),
                  ),
                  title: Text(
                    sale.number.isEmpty ? 'Vente' : sale.number,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${sale.product}\n${sale.client} • ${sale.payment} • ${sale.date} ${sale.time}',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    '${money(sale.amount)} F',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _saleActions(BuildContext context, SaleRecord sale) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  sale.product,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text('${money(sale.amount)} FCFA • ${sale.payment}'),
              ),
              ListTile(
                leading: const Icon(Icons.print_outlined, color: _green),
                title: const Text('Imprimer le ticket'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _printInvoice(sale);
                },
              ),
              ListTile(
                leading: const Icon(Icons.chat_outlined, color: _green),
                title: const Text('Envoyer par WhatsApp'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openMessage(context, sale, whatsapp: true);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.sms_outlined,
                  color: Color(0xFF4776B7),
                ),
                title: const Text('Envoyer par SMS'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openMessage(context, sale, whatsapp: false);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _printInvoice(SaleRecord sale) async {
    final prefs = await SharedPreferences.getInstance();
    await Printing.layoutPdf(
      onLayout: (_) => buildSaleReceipt(sale),
      format: saleReceiptFormat(
        sale,
        footerMessage:
            sale.receiptMessage ??
            prefs.getString(receiptFooterKey) ??
            defaultReceiptFooter,
      ),
      name: '${sale.number.isEmpty ? 'ticket-moncommerce' : sale.number}.pdf',
    );
  }

  Future<void> _openMessage(
    BuildContext context,
    SaleRecord sale, {
    required bool whatsapp,
  }) async {
    final message =
        'MonCommerce - Reçu : ${sale.product}, total ${money(sale.amount)} FCFA, paiement ${sale.payment}.';
    final uri = whatsapp
        ? Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}')
        : Uri(scheme: 'sms', queryParameters: {'body': message});
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune application compatible trouvée.')),
      );
    }
  }
}

class ProductsPage extends StatelessWidget {
  const ProductsPage({
    super.key,
    required this.products,
    required this.onChanged,
  });
  final List<Product> products;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const PageHeader('Produits', 'Gérez vos articles et votre stock'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Rechercher un produit',
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'Lire le nom avec la caméra',
              onPressed: () async {
                final text = await _scanProductName(context);
                if (text != null && context.mounted) {
                  _addProduct(context, initialName: text);
                }
              },
              icon: const Icon(Icons.document_scanner_outlined),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Scanner un code-barres',
              onPressed: () async {
                final code = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(builder: (_) => const BarcodeScannerPage()),
                );
                if (code != null && context.mounted) {
                  _addProduct(context, barcode: code);
                }
              },
              icon: const Icon(Icons.qr_code_scanner_rounded),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: () => _addProduct(context),
              icon: const Icon(Icons.add),
            ),
            PopupMenuButton<String>(
              tooltip: 'Import, export et inventaire',
              icon: const Icon(Icons.upload_file),
              onSelected: (value) {
                switch (value) {
                  case 'template':
                    _saveImportTemplate(context);
                    break;
                  case 'export':
                    _exportProducts(context);
                    break;
                  case 'inventory':
                    _inventory(context);
                    break;
                  case 'restock':
                    _inventory(context, restock: true);
                    break;
                  case 'value':
                    showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        content: SizedBox(
                          width: 560,
                          child: SingleChildScrollView(
                            child: StockValueCard(
                              value: StockValue(
                                products.map(
                                  (p) => (
                                    stock: p.stock,
                                    price: p.price,
                                    purchasePrice: p.purchasePrice,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Fermer'),
                          ),
                        ],
                      ),
                    );
                    break;
                  default:
                    _importProducts(context);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'import',
                  child: Text('Importer un fichier Excel'),
                ),
                PopupMenuItem(
                  value: 'template',
                  child: Text('Télécharger le modèle Excel'),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: Text('Exporter les produits Excel'),
                ),
                PopupMenuItem(
                  value: 'inventory',
                  child: Text('Faire un inventaire'),
                ),
                PopupMenuItem(
                  value: 'restock',
                  child: Text('Ajouter du stock aux articles'),
                ),
                PopupMenuItem(
                  value: 'value',
                  child: Text('Voir la valeur de la boutique'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
          itemCount: products.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (_, index) {
            final p = products[index];
            final low = p.stock <= 6;
            return Card(
              child: ListTile(
                onTap: () => _addProduct(context, existing: p),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 8,
                ),
                leading: CircleAvatar(
                  backgroundColor: _green.withValues(alpha: .1),
                  backgroundImage:
                      p.imagePath.isNotEmpty && File(p.imagePath).existsSync()
                      ? FileImage(File(p.imagePath))
                      : p.imageUrl.isNotEmpty
                      ? NetworkImage(p.imageUrl)
                      : null,
                  child:
                      (p.imagePath.isEmpty ||
                              !File(p.imagePath).existsSync()) &&
                          p.imageUrl.isEmpty
                      ? Icon(p.icon, color: _green)
                      : null,
                ),
                title: Text(
                  p.name,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  p.barcode.isEmpty
                      ? '${money(p.price)} FCFA'
                      : '${money(p.price)} FCFA • ${p.barcode}',
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${p.stock} en stock',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: low ? const Color(0xFFD56A4D) : _green,
                      ),
                    ),
                    if (low)
                      const Text(
                        'Stock faible',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFFD56A4D),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ],
  );

  Future<String?> _scanProductName(BuildContext context) async {
    if (Platform.isWindows) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'La lecture automatique de texte est disponible sur mobile. Ajoutez une photo du produit depuis le formulaire Windows.',
          ),
        ),
      );
      return null;
    }
    final image = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (image == null) return null;
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(
        InputImage.fromFilePath(image.path),
      );
      final lines = result.blocks
          .expand((block) => block.lines)
          .map((line) => line.text.trim())
          .where((line) => line.length > 2)
          .toList();
      if (lines.isEmpty && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aucun nom lisible détecté.')),
        );
      }
      return lines.isEmpty ? null : lines.first;
    } finally {
      await recognizer.close();
    }
  }

  void _addProduct(
    BuildContext context, {
    String barcode = '',
    String initialName = '',
    Product? existing,
  }) {
    final name = TextEditingController(text: existing?.name ?? initialName);
    final price = TextEditingController(text: existing?.price.toString() ?? '');
    final purchasePrice = TextEditingController(
      text: existing?.purchasePrice?.toString() ?? '',
    );
    String? purchasePriceError;
    final stock = TextEditingController(text: existing?.stock.toString() ?? '');
    final barcodeController = TextEditingController(
      text: existing?.barcode ?? barcode,
    );
    var imagePath = existing?.imagePath ?? '';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? 'Nouveau produit' : 'Modifier le produit',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Nom du produit',
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final path = await selectProductPhoto();
                      if (path != null && dialogContext.mounted)
                        setDialogState(() => imagePath = path);
                    } catch (_) {
                      if (dialogContext.mounted)
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Photo illisible. Choisissez une image JPG, PNG ou WebP de moins de 10 Mo.',
                            ),
                          ),
                        );
                    }
                  },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choisir une photo dans les fichiers'),
                ),
                if (imagePath.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Image.file(
                      File(imagePath),
                      height: 90,
                      width: 140,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Text('Photo indisponible'),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () async {
                    if (Platform.isWindows) {
                      final path = await Navigator.push<String>(
                        dialogContext,
                        MaterialPageRoute(
                          builder: (_) => const DesktopCameraCapturePage(),
                        ),
                      );
                      if (path != null && dialogContext.mounted) {
                        setDialogState(() => imagePath = path);
                      }
                      return;
                    }
                    final source = await showModalBottomSheet<ImageSource>(
                      context: dialogContext,
                      builder: (context) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.photo_camera_outlined),
                              title: const Text('Prendre une photo'),
                              onTap: () =>
                                  Navigator.pop(context, ImageSource.camera),
                            ),
                            ListTile(
                              leading: const Icon(Icons.photo_library_outlined),
                              title: const Text('Importer depuis la galerie'),
                              onTap: () =>
                                  Navigator.pop(context, ImageSource.gallery),
                            ),
                          ],
                        ),
                      ),
                    );
                    if (source == null) return;
                    final image = await ImagePicker().pickImage(
                      source: source,
                      imageQuality: 75,
                      maxWidth: 1600,
                    );
                    if (image != null) {
                      setDialogState(() => imagePath = image.path);
                    }
                  },
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: Text(
                    imagePath.isEmpty
                        ? 'Ajouter une photo'
                        : 'Changer la photo',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Prix de vente'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: purchasePrice,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Prix d’achat (FCFA)',
                    helperText: 'Facultatif • coût unitaire',
                    errorText: purchasePriceError,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: stock,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Stock initial'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: barcodeController,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: 'Code-barres',
                    hintText: 'Touchez le scanner',
                    prefixIcon: const Icon(Icons.qr_code_rounded),
                    suffixIcon: IconButton(
                      tooltip: 'Scanner le code-barres',
                      onPressed: () async {
                        final code = await Navigator.push<String>(
                          dialogContext,
                          MaterialPageRoute(
                            builder: (_) => const BarcodeScannerPage(),
                          ),
                        );
                        if (code != null && dialogContext.mounted) {
                          barcodeController.text = code;
                          setDialogState(() {});
                        }
                      },
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                final rawPurchasePrice = purchasePrice.text.trim();
                final parsedPurchasePrice = int.tryParse(rawPurchasePrice);
                if (rawPurchasePrice.isNotEmpty &&
                    (parsedPurchasePrice == null || parsedPurchasePrice < 0)) {
                  setDialogState(
                    () => purchasePriceError =
                        'Saisissez un montant entier positif ou nul.',
                  );
                  return;
                }
                if (existing == null) {
                  products.add(
                    Product(
                      name.text.trim(),
                      int.tryParse(price.text) ?? 0,
                      int.tryParse(stock.text) ?? 0,
                      Icons.inventory_2_outlined,
                      barcode: barcodeController.text.trim(),
                      imagePath: imagePath,
                      purchasePrice: parsedPurchasePrice,
                    ),
                  );
                } else {
                  existing.name = name.text.trim();
                  existing.price = int.tryParse(price.text) ?? existing.price;
                  existing.purchasePrice = parsedPurchasePrice;
                  existing.stock = int.tryParse(stock.text) ?? existing.stock;
                  existing.barcode = barcodeController.text.trim();
                  existing.imagePath = imagePath;
                }
                onChanged();
                Navigator.pop(dialogContext);
              },
              child: Text(existing == null ? 'Ajouter' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveImportTemplate(BuildContext context) async {
    try {
      final bytes = Uint8List.fromList(productImportTemplate());
      final destination = await FilePicker.saveFile(
        dialogTitle: 'Enregistrer le modèle Excel',
        fileName: 'modele-produits-moncommerce.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: bytes,
      );
      if (destination != null && context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Modèle Excel enregistré. Remplissez la feuille Produits.',
            ),
          ),
        );
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Impossible d’enregistrer le modèle Excel.'),
          ),
        );
    }
  }

  Future<void> _exportProducts(BuildContext context) async {
    try {
      final bytes = exportProductWorkbook(
        products.map(
          (p) => ImportedProduct(
            name: p.name,
            price: p.price,
            stock: p.stock,
            purchasePrice: p.purchasePrice,
            barcode: p.barcode,
          ),
        ),
      );
      final path = await FilePicker.saveFile(
        dialogTitle: 'Exporter les produits',
        fileName:
            'produits-${DateTime.now().toIso8601String().substring(0, 10)}.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: Uint8List.fromList(bytes),
      );
      if (path != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Produits exportés en Excel.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d’exporter les produits.')),
        );
      }
    }
  }

  Future<void> _inventory(BuildContext context, {bool restock = false}) async {
    if (products.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ajoutez d’abord des articles avec le bouton + ou l’import Excel.',
          ),
        ),
      );
      return;
    }
    final snapshot = products.toList();
    final stocks = snapshot.map((p) => p.stock).toList();
    final values = await showDialog<List<int?>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InventoryDialog(
        entries: snapshot
            .map((p) => InventoryEntry(p.name, p.barcode, p.stock))
            .toList(),
        restock: restock,
      ),
    );
    if (values == null || !context.mounted) {
      return;
    }
    for (var i = 0; i < snapshot.length; i++) {
      if (values[i] != null &&
          (!products.contains(snapshot[i]) || snapshot[i].stock != stocks[i])) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Le stock a changé pendant la saisie. Recommencez avec les quantités actualisées.',
            ),
          ),
        );
        return;
      }
    }
    for (var i = 0; i < snapshot.length; i++) {
      if (values[i] != null) {
        snapshot[i].stock = restock ? stocks[i] + values[i]! : values[i]!;
      }
    }
    onChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          restock
              ? 'Réapprovisionnement enregistré.'
              : 'Inventaire enregistré : stocks mis à jour.',
        ),
      ),
    );
  }

  Future<void> _importProducts(BuildContext context) async {
    try {
      final selection = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );
      if (selection == null) return;
      final file = selection.files.single;
      if (file.size > 10 * 1024 * 1024)
        throw const FormatException(
          'Choisissez un fichier Excel de moins de 10 Mo.',
        );
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      final result = parseProductWorkbook(
        bytes,
        existingNames: products.map((p) => p.name),
        existingBarcodes: products.map((p) => p.barcode),
      );
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Vérifier l’importation Excel'),
          content: SizedBox(
            width: 560,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Feuille : ${result.sheetName}\n${result.products.length} produit(s) à ajouter • ${result.issues.length} ligne(s) ignorée(s)',
                ),
                const SizedBox(height: 8),
                const Text('Les produits existants ne seront pas modifiés.'),
                const Divider(),
                Expanded(
                  child: ListView(
                    children: [
                      for (final issue in result.issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            issue,
                            style: const TextStyle(color: Color(0xFFB3261E)),
                          ),
                        ),
                      for (final warning in result.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(warning),
                        ),
                      for (final row in result.products)
                        ListTile(
                          dense: true,
                          title: Text(row.name),
                          subtitle: Text(
                            '${money(row.price)} FCFA • stock ${row.stock}${row.barcode.isEmpty ? "" : " • ${row.barcode}"}',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: result.products.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: Text('Importer ${result.products.length} produits'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      products.addAll(
        result.products.map(
          (row) => Product(
            row.name,
            row.price,
            row.stock,
            Icons.inventory_2_outlined,
            purchasePrice: row.purchasePrice,
            barcode: row.barcode,
          ),
        ),
      );
      onChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${result.products.length} produit(s) importé(s).'),
        ),
      );
    } on FormatException catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Fichier illisible. Utilisez un classeur Excel .xlsx non protégé.',
            ),
          ),
        );
    }
  }
}

Future<String?> selectProductPhoto() async {
  final selected = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
  );
  if (selected == null) return null;
  final file = selected.files.single;
  if (file.path == null || file.size > 10 * 1024 * 1024)
    throw const FormatException('Image invalide');
  final bytes = await File(file.path!).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1600);
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  if (png == null) throw const FormatException('Image illisible');
  final support = await getApplicationSupportDirectory();
  final directory = await Directory(
    '${support.path}${Platform.pathSeparator}product_images',
  ).create(recursive: true);
  final destination = File(
    '${directory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await destination.writeAsBytes(png.buffer.asUint8List(), flush: true);
  return destination.path;
}

class UpdateDownloadButton extends StatefulWidget {
  const UpdateDownloadButton({
    super.key,
    required this.downloadUrl,
    required this.version,
  });

  final String downloadUrl;
  final String version;

  @override
  State<UpdateDownloadButton> createState() => _UpdateDownloadButtonState();
}

class _UpdateDownloadButtonState extends State<UpdateDownloadButton> {
  bool _downloading = false;
  double _progress = 0;

  Future<void> _downloadAndInstall() async {
    if (_downloading) return;
    if (!Platform.isAndroid) {
      await launchUrl(
        Uri.parse(widget.downloadUrl),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    try {
      final path = await _downloadUpdateApk(
        widget.downloadUrl,
        widget.version,
        (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() => _downloading = false);
      await _installUpdateApk(path);
    } catch (_) {
      if (!mounted) return;
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Téléchargement impossible. Vérifiez votre connexion et réessayez.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: _downloading ? null : _downloadAndInstall,
    icon: _downloading
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.download),
    label: Text(
      _downloading
          ? 'Téléchargement ${(_progress * 100).round()} %'
          : 'Télécharger et installer',
    ),
  );
}

class AnnouncementsPage extends StatelessWidget {
  const AnnouncementsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Notifications et mises à jour')),
    body: StreamBuilder<List<Map<String, dynamic>>>(
      stream: supabase
          .from('app_announcements')
          .stream(primaryKey: ['id'])
          .order('created_at', ascending: false),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Text('Chargement impossible : ${snapshot.error}'),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snapshot.data!;
        if (items.isEmpty) {
          return const Center(child: Text('Aucune notification disponible'));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(18),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(height: 12),
          itemBuilder: (_, index) {
            final item = items[index];
            final isUpdate = item['kind'] == 'update';
            final createdAt = DateTime.tryParse(
              '${item['created_at']}',
            )?.toLocal();
            final date = createdAt == null
                ? ''
                : '${createdAt.day.toString().padLeft(2, '0')}/${createdAt.month.toString().padLeft(2, '0')}/${createdAt.year}';
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: isUpdate
                              ? const Color(0xFFFFF3D6)
                              : const Color(0xFFE1F1EA),
                          child: Icon(
                            isUpdate
                                ? Icons.system_update
                                : Icons.notifications,
                            color: isUpdate ? _orange : _green,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${item['title']}',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                isUpdate
                                    ? 'Version ${item['version']} • $date'
                                    : date,
                                style: const TextStyle(color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                        if (item['is_mandatory'] == true)
                          const Chip(label: Text('Obligatoire')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('${item['body']}'),
                    if (isUpdate) ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: UpdateDownloadButton(
                          downloadUrl: '${item['download_url']}',
                          version: '${item['version']}',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}

class AdminMonitoringPage extends StatefulWidget {
  const AdminMonitoringPage({super.key});

  @override
  State<AdminMonitoringPage> createState() => _AdminMonitoringPageState();
}

class _AdminMonitoringPageState extends State<AdminMonitoringPage> {
  bool loading = true;
  String? error;
  String severity = 'all';
  List<Map<String, dynamic>> presence = [];
  List<Map<String, dynamic>> logs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final results = await Future.wait([
        supabase
            .from('app_user_presence')
            .select()
            .order('last_seen', ascending: false),
        supabase
            .from('app_activity_logs')
            .select()
            .order('created_at', ascending: false)
            .limit(250),
      ]);
      if (!mounted) return;
      setState(() {
        presence = List<Map<String, dynamic>>.from(results[0]);
        logs = List<Map<String, dynamic>>.from(results[1]);
        error = null;
        loading = false;
      });
    } on PostgrestException catch (exception) {
      if (!mounted) return;
      setState(() {
        error = exception.message;
        loading = false;
      });
    }
  }

  DateTime? _date(dynamic value) => DateTime.tryParse('$value')?.toLocal();

  String _dateLabel(dynamic value) {
    final date = _date(value);
    if (date == null) return 'Date inconnue';
    final now = DateTime.now();
    final difference = now.difference(date);
    if (difference.inMinutes < 1) return 'À l\'instant';
    if (difference.inMinutes < 60) return 'Il y a ${difference.inMinutes} min';
    if (difference.inHours < 24) return 'Il y a ${difference.inHours} h';
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  bool _isOnline(Map<String, dynamic> row) {
    final lastSeen = _date(row['last_seen']);
    return lastSeen != null &&
        DateTime.now().difference(lastSeen) < const Duration(minutes: 10);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final last24Hours = now.subtract(const Duration(hours: 24));
    final recentLogs = logs
        .where(
          (row) =>
              (_date(row['created_at']) ?? DateTime(2000)).isAfter(last24Hours),
        )
        .toList();
    final onlineCount = presence.where(_isOnline).length;
    final errorCount = recentLogs
        .where((row) => row['severity'] == 'error')
        .length;
    final visibleLogs = severity == 'all'
        ? logs
        : logs.where((row) => row['severity'] == severity).toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Monitoring Super Admin'),
          actions: [
            IconButton(
              onPressed: loading ? null : _load,
              tooltip: 'Actualiser',
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.monitor_heart_outlined), text: 'Présence'),
              Tab(icon: Icon(Icons.receipt_long_outlined), text: 'Journaux'),
            ],
          ),
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 52),
                      const SizedBox(height: 12),
                      Text('Chargement impossible : $error'),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Réessayer'),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Row(
                      children: [
                        _metric(
                          'En ligne',
                          '$onlineCount',
                          Icons.circle,
                          Colors.green,
                        ),
                        _metric(
                          'Utilisateurs',
                          '${presence.length}',
                          Icons.people_outline,
                          _green,
                        ),
                        _metric(
                          'Actions 24 h',
                          '${recentLogs.length}',
                          Icons.bolt_outlined,
                          Colors.blue,
                        ),
                        _metric(
                          'Erreurs 24 h',
                          '$errorCount',
                          Icons.error_outline,
                          Colors.red,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        RefreshIndicator(
                          onRefresh: _load,
                          child: presence.isEmpty
                              ? ListView(
                                  children: const [
                                    SizedBox(height: 180),
                                    Center(
                                      child: Text('Aucun utilisateur suivi'),
                                    ),
                                  ],
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    24,
                                  ),
                                  itemCount: presence.length,
                                  separatorBuilder: (_, _) =>
                                      const SizedBox(height: 8),
                                  itemBuilder: (_, index) {
                                    final row = presence[index];
                                    final online = _isOnline(row);
                                    return Card(
                                      child: ListTile(
                                        contentPadding: const EdgeInsets.all(
                                          14,
                                        ),
                                        leading: CircleAvatar(
                                          backgroundColor:
                                              (online
                                                      ? Colors.green
                                                      : Colors.grey)
                                                  .withValues(alpha: .12),
                                          child: Icon(
                                            online
                                                ? Icons.wifi
                                                : Icons.wifi_off,
                                            color: online
                                                ? Colors.green
                                                : Colors.grey,
                                          ),
                                        ),
                                        title: Text(
                                          '${row['shop_name']}'.trim().isEmpty
                                              ? 'Boutique sans nom'
                                              : '${row['shop_name']}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                        subtitle: Text(
                                          '${online ? 'En ligne' : _dateLabel(row['last_seen'])}\nDernière action : ${row['last_action']} • ${row['platform']} • v${row['app_version']}',
                                        ),
                                        isThreeLine: true,
                                      ),
                                    );
                                  },
                                ),
                        ),
                        Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                              child: DropdownButtonFormField<String>(
                                initialValue: severity,
                                decoration: const InputDecoration(
                                  labelText: 'Filtrer les journaux',
                                  prefixIcon: Icon(Icons.filter_list),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'all',
                                    child: Text('Tous les niveaux'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'info',
                                    child: Text('Informations'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'warning',
                                    child: Text('Avertissements'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'error',
                                    child: Text('Erreurs'),
                                  ),
                                ],
                                onChanged: (value) =>
                                    setState(() => severity = value!),
                              ),
                            ),
                            Expanded(
                              child: RefreshIndicator(
                                onRefresh: _load,
                                child: visibleLogs.isEmpty
                                    ? ListView(
                                        children: const [
                                          SizedBox(height: 150),
                                          Center(
                                            child: Text(
                                              'Aucun journal disponible',
                                            ),
                                          ),
                                        ],
                                      )
                                    : ListView.separated(
                                        padding: const EdgeInsets.fromLTRB(
                                          16,
                                          8,
                                          16,
                                          24,
                                        ),
                                        itemCount: visibleLogs.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(height: 8),
                                        itemBuilder: (_, index) =>
                                            _logTile(visibleLogs[index]),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _metric(String label, String value, IconData icon, Color color) =>
      Container(
        width: 142,
        margin: const EdgeInsets.only(right: 9),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .09),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 7),
            Text(
              value,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            Text(label, style: const TextStyle(color: Colors.black54)),
          ],
        ),
      );

  Widget _logTile(Map<String, dynamic> row) {
    final level = '${row['severity']}';
    final color = switch (level) {
      'error' => Colors.red,
      'warning' => _orange,
      _ => Colors.blue,
    };
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(14),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: .10),
          child: Icon(
            level == 'error' ? Icons.error_outline : Icons.history,
            color: color,
          ),
        ),
        title: Text(
          '${row['description']}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '${row['shop_name']} • ${row['event_type']}\n${_dateLabel(row['created_at'])}',
        ),
        isThreeLine: true,
      ),
    );
  }
}

class AdminBroadcastPage extends StatefulWidget {
  const AdminBroadcastPage({super.key});

  @override
  State<AdminBroadcastPage> createState() => _AdminBroadcastPageState();
}

class _AdminBroadcastPageState extends State<AdminBroadcastPage> {
  final title = TextEditingController();
  final body = TextEditingController();
  final version = TextEditingController();
  bool isUpdate = false;
  bool mandatory = false;
  bool publishing = false;
  PlatformFile? apk;

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    version.dispose();
    super.dispose();
  }

  Future<void> _pickApk() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['apk'],
    );
    if (result != null) setState(() => apk = result.files.single);
  }

  Future<void> _publish() async {
    if (title.text.trim().isEmpty || body.text.trim().isEmpty) {
      _message('Ajoutez un titre et un message.');
      return;
    }
    if (isUpdate && (version.text.trim().isEmpty || apk?.path == null)) {
      _message('Indiquez la version et sélectionnez le fichier APK.');
      return;
    }
    setState(() => publishing = true);
    try {
      String? downloadUrl;
      if (isUpdate) {
        final safeVersion = version.text.trim().replaceAll(
          RegExp(r'[^a-zA-Z0-9._-]'),
          '-',
        );
        final path =
            'moncommerce-$safeVersion-${DateTime.now().millisecondsSinceEpoch}.apk';
        await supabase.storage
            .from('app-updates')
            .upload(
              path,
              File(apk!.path!),
              fileOptions: const FileOptions(
                contentType: 'application/vnd.android.package-archive',
              ),
            );
        downloadUrl = supabase.storage.from('app-updates').getPublicUrl(path);
      }
      final announcement = await supabase
          .from('app_announcements')
          .insert({
            'kind': isUpdate ? 'update' : 'notification',
            'title': title.text.trim(),
            'body': body.text.trim(),
            'version': isUpdate ? version.text.trim() : null,
            'download_url': downloadUrl,
            'is_mandatory': isUpdate && mandatory,
            'created_by': supabase.auth.currentUser!.id,
          })
          .select('id')
          .single();
      var pushSent = false;
      if (isUpdate) {
        try {
          final response = await supabase.functions.invoke(
            'send-update-notification',
            body: {
              'announcementId': announcement['id'],
              'title': title.text.trim(),
              'body': body.text.trim(),
              'version': version.text.trim(),
              'downloadUrl': downloadUrl,
              'mandatory': mandatory,
            },
          );
          final data = response.data;
          pushSent = data is Map && data['sent'] == true;
        } catch (_) {}
      }
      if (!mounted) return;
      _message(
        isUpdate
            ? pushSent
                  ? 'Mise à jour publiée et notification envoyée.'
                  : 'Mise à jour publiée. Déployez la fonction de notification pour alerter les appareils fermés.'
            : 'Notification envoyée.',
      );
      title.clear();
      body.clear();
      version.clear();
      setState(() {
        apk = null;
        mandatory = false;
      });
    } on StorageException catch (error) {
      _message('Envoi du fichier impossible : ${error.message}');
    } on PostgrestException catch (error) {
      _message('Publication impossible : ${error.message}');
    } finally {
      if (mounted) setState(() => publishing = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Diffusion aux utilisateurs')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              icon: Icon(Icons.notifications_outlined),
              label: Text('Notification'),
            ),
            ButtonSegment(
              value: true,
              icon: Icon(Icons.system_update),
              label: Text('Mise à jour'),
            ),
          ],
          selected: {isUpdate},
          onSelectionChanged: (value) => setState(() => isUpdate = value.first),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: title,
          decoration: const InputDecoration(labelText: 'Titre'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: body,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'Message aux utilisateurs',
          ),
        ),
        if (isUpdate) ...[
          const SizedBox(height: 12),
          TextField(
            controller: version,
            decoration: const InputDecoration(
              labelText: 'Numéro de version',
              hintText: 'Exemple : 1.1.0',
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              onTap: _pickApk,
              leading: const Icon(Icons.android, color: _green),
              title: Text(apk?.name ?? 'Sélectionner le fichier APK'),
              subtitle: const Text('Paquet Android à envoyer aux utilisateurs'),
              trailing: const Icon(Icons.upload_file),
            ),
          ),
          SwitchListTile(
            value: mandatory,
            onChanged: (value) => setState(() => mandatory = value),
            title: const Text('Mise à jour obligatoire'),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: publishing ? null : _publish,
            icon: publishing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: Text(publishing ? 'Envoi en cours…' : 'Publier'),
          ),
        ),
      ],
    ),
  );
}

class CommercialLine {
  CommercialLine(
    this.description,
    this.quantity,
    this.unitPrice, {
    this.observation = '',
  });
  final String description;
  final int quantity;
  final int unitPrice;
  final String observation;
  int get total => quantity * unitPrice;

  Map<String, dynamic> toJson() => {
    'description': description,
    'quantity': quantity,
    'unitPrice': unitPrice,
    'observation': observation,
  };

  factory CommercialLine.fromJson(Map<String, dynamic> json) => CommercialLine(
    json['description'] as String,
    json['quantity'] as int,
    json['unitPrice'] as int,
    observation: json['observation'] as String? ?? '',
  );
}

class CommercialCustomer {
  CommercialCustomer({
    required this.name,
    required this.phone,
    required this.address,
    required this.isCompany,
  });

  final String name;
  final String phone;
  final String address;
  final bool isCompany;

  Map<String, dynamic> toJson() => {
    'name': name,
    'phone': phone,
    'address': address,
    'isCompany': isCompany,
  };

  factory CommercialCustomer.fromJson(Map<String, dynamic> json) =>
      CommercialCustomer(
        name: json['name'] as String,
        phone: json['phone'] as String? ?? '',
        address: json['address'] as String? ?? '',
        isCompany: json['isCompany'] as bool? ?? false,
      );
}

class CommercialDocument {
  CommercialDocument({
    required this.type,
    required this.number,
    required this.client,
    required this.phone,
    required this.address,
    required this.object,
    required this.purchaseOrderNumber,
    required this.notes,
    required this.createdAt,
    required this.lines,
  });
  final String type,
      number,
      client,
      phone,
      address,
      object,
      purchaseOrderNumber,
      notes;
  final DateTime createdAt;
  final List<CommercialLine> lines;
  int get total => lines.fold(0, (sum, line) => sum + line.total);

  Map<String, dynamic> toJson() => {
    'type': type,
    'number': number,
    'client': client,
    'phone': phone,
    'address': address,
    'object': object,
    'purchaseOrderNumber': purchaseOrderNumber,
    'notes': notes,
    'createdAt': createdAt.toIso8601String(),
    'lines': lines.map((line) => line.toJson()).toList(),
  };

  factory CommercialDocument.fromJson(Map<String, dynamic> json) =>
      CommercialDocument(
        type: json['type'] as String,
        number: json['number'] as String,
        client: json['client'] as String,
        phone: json['phone'] as String? ?? '',
        address: json['address'] as String? ?? '',
        object: json['object'] as String? ?? '',
        purchaseOrderNumber: json['purchaseOrderNumber'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        lines: (json['lines'] as List)
            .map(
              (line) => CommercialLine.fromJson(
                Map<String, dynamic>.from(line as Map),
              ),
            )
            .toList(),
      );
}

class CommercialDocumentsPage extends StatefulWidget {
  const CommercialDocumentsPage({super.key, required this.products});
  final List<Product> products;

  @override
  State<CommercialDocumentsPage> createState() =>
      _CommercialDocumentsPageState();
}

class _CommercialDocumentsPageState extends State<CommercialDocumentsPage> {
  static const _storageKey = 'commercial_documents_v1';
  static const _customersStorageKey = 'commercial_document_customers_v1';
  static const _headerImageKey = 'commercial_document_header_image_v1';
  static const _footerImageKey = 'commercial_document_footer_image_v1';
  static const _stampImageKey = 'commercial_document_stamp_image_v1';
  static const _signatureImageKey = 'commercial_document_signature_image_v1';
  static const _templateKey = 'commercial_document_template_v1';
  static const _showShopNameKey = 'commercial_document_show_shop_name_v1';
  static const _headerHeightKey = 'commercial_document_header_height_v1';
  static const _footerHeightKey = 'commercial_document_footer_height_v1';
  final documents = <CommercialDocument>[];
  final customers = <CommercialCustomer>[];
  final selectedDeliveryNotes = <CommercialDocument>{};
  bool selectingDeliveryNotes = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    final rawCustomers = prefs.getString(_customersStorageKey);
    if (!mounted) return;
    final loadedDocuments = raw == null
        ? <CommercialDocument>[]
        : (jsonDecode(raw) as List)
              .map(
                (item) => CommercialDocument.fromJson(
                  Map<String, dynamic>.from(item as Map),
                ),
              )
              .toList();
    final loadedCustomers = rawCustomers == null
        ? <CommercialCustomer>[]
        : (jsonDecode(rawCustomers) as List)
              .map(
                (item) => CommercialCustomer.fromJson(
                  Map<String, dynamic>.from(item as Map),
                ),
              )
              .toList();
    for (final document in loadedDocuments) {
      if (document.client.isEmpty ||
          loadedCustomers.any(
            (customer) =>
                customer.name.toLowerCase() == document.client.toLowerCase(),
          )) {
        continue;
      }
      loadedCustomers.add(
        CommercialCustomer(
          name: document.client,
          phone: document.phone,
          address: document.address,
          isCompany: false,
        ),
      );
    }
    setState(() {
      documents.addAll(loadedDocuments);
      customers.addAll(loadedCustomers);
    });
    if (rawCustomers == null && loadedCustomers.isNotEmpty)
      await _saveCustomers();
  }

  Future<void> _save() async =>
      (await SharedPreferences.getInstance()).setString(
        _storageKey,
        jsonEncode(documents.map((document) => document.toJson()).toList()),
      );

  Future<void> _saveCustomers() async =>
      (await SharedPreferences.getInstance()).setString(
        _customersStorageKey,
        jsonEncode(customers.map((customer) => customer.toJson()).toList()),
      );

  Future<void> _rememberCustomer(CommercialDocument document) async {
    final existingIndex = customers.indexWhere(
      (item) => item.name.toLowerCase() == document.client.toLowerCase(),
    );
    final customer = CommercialCustomer(
      name: document.client,
      phone: document.phone,
      address: document.address,
      isCompany: existingIndex >= 0
          ? customers[existingIndex].isCompany
          : false,
    );
    setState(() {
      if (existingIndex < 0) {
        customers.add(customer);
      } else {
        customers[existingIndex] = customer;
      }
    });
    await _saveCustomers();
  }

  Future<void> _create() async {
    final document = await Navigator.push<CommercialDocument>(
      context,
      MaterialPageRoute(
        builder: (_) => CommercialDocumentEditor(
          products: widget.products,
          customers: customers,
        ),
      ),
    );
    if (document == null) return;
    setState(() => documents.insert(0, document));
    await _rememberCustomer(document);
    await _save();
    unawaited(
      _logActivity(
        'document_created',
        '${document.type} ${document.number} créé',
        metadata: {
          'document_type': document.type,
          'document_number': document.number,
          'amount': document.total,
        },
      ),
    );
  }

  Future<void> _edit(CommercialDocument document, int index) async {
    final updated = await Navigator.push<CommercialDocument>(
      context,
      MaterialPageRoute(
        builder: (_) => CommercialDocumentEditor(
          products: widget.products,
          customers: customers,
          document: document,
        ),
      ),
    );
    if (updated == null) return;
    setState(() => documents[index] = updated);
    await _rememberCustomer(updated);
    await _save();
    unawaited(
      _logActivity(
        'document_updated',
        '${updated.type} ${updated.number} modifié',
        metadata: {
          'document_type': updated.type,
          'document_number': updated.number,
          'amount': updated.total,
        },
      ),
    );
  }

  String? _nextDocumentType(String type) => switch (type) {
    'Devis' => 'Facture pro forma',
    'Facture pro forma' => 'Facture définitive',
    'Facture définitive' => 'Bordereau de livraison',
    _ => null,
  };

  String _newDocumentNumber(String type, DateTime now) {
    final prefix = switch (type) {
      'Devis' => 'DEV',
      'Facture pro forma' => 'PRO',
      'Facture définitive' => 'FAC',
      'Bordereau de livraison' => 'BL',
      _ => 'BC',
    };
    final suffix = now.millisecondsSinceEpoch.toString();
    return '$prefix-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${suffix.substring(suffix.length - 5)}';
  }

  Future<void> _evolve(CommercialDocument source) async {
    final targetType = _nextDocumentType(source.type);
    if (targetType == null) return;
    final now = DateTime.now();
    final evolved = CommercialDocument(
      type: targetType,
      number: _newDocumentNumber(targetType, now),
      client: source.client,
      phone: source.phone,
      address: source.address,
      object: source.object,
      purchaseOrderNumber: source.purchaseOrderNumber,
      notes: source.notes,
      createdAt: now,
      lines: source.lines
          .map(
            (line) => CommercialLine(
              line.description,
              line.quantity,
              line.unitPrice,
              observation: line.observation,
            ),
          )
          .toList(),
    );
    setState(() => documents.insert(0, evolved));
    await _save();
    unawaited(
      _logActivity(
        'document_evolved',
        '${source.type} transformé en $targetType',
        metadata: {
          'source_number': source.number,
          'target_number': evolved.number,
          'target_type': targetType,
        },
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$targetType ${evolved.number} créé avec succès')),
    );
  }

  Future<void> _duplicateInvoice(CommercialDocument source) async {
    final duplicate = await Navigator.push<CommercialDocument>(
      context,
      MaterialPageRoute(
        builder: (_) => CommercialDocumentEditor(
          products: widget.products,
          customers: customers,
          document: source,
          createAsNew: true,
        ),
      ),
    );
    if (duplicate == null) return;
    setState(() => documents.insert(0, duplicate));
    await _rememberCustomer(duplicate);
    await _save();
    unawaited(
      _logActivity(
        'document_duplicated',
        'Facture ${source.number} dupliquée en ${duplicate.number}',
        metadata: {
          'source_number': source.number,
          'target_number': duplicate.number,
          'document_type': duplicate.type,
        },
      ),
    );
  }

  Future<void> _createInvoiceFromDeliveryNotes() async {
    final selected = selectedDeliveryNotes.toList();
    if (selected.isEmpty) return;
    final first = selected.first;
    final now = DateTime.now();
    final draft = CommercialDocument(
      type: 'Facture définitive',
      number: _newDocumentNumber('Facture définitive', now),
      client: first.client,
      phone: first.phone,
      address: first.address,
      object: selected.length == 1
          ? first.object
          : 'Facture des bordereaux ${selected.map((note) => note.number).join(', ')}',
      purchaseOrderNumber: first.purchaseOrderNumber,
      notes: selected
          .where((note) => note.notes.isNotEmpty)
          .map((note) => note.notes)
          .join('\n'),
      createdAt: now,
      lines: selected
          .expand((note) => note.lines)
          .map(
            (line) => CommercialLine(
              line.description,
              line.quantity,
              line.unitPrice,
              observation: line.observation,
            ),
          )
          .toList(),
    );
    final invoice = await Navigator.push<CommercialDocument>(
      context,
      MaterialPageRoute(
        builder: (_) => CommercialDocumentEditor(
          products: widget.products,
          customers: customers,
          document: draft,
          createAsNew: true,
        ),
      ),
    );
    if (invoice == null) return;
    setState(() {
      documents.insert(0, invoice);
      selectedDeliveryNotes.clear();
      selectingDeliveryNotes = false;
    });
    await _rememberCustomer(invoice);
    await _save();
    unawaited(
      _logActivity(
        'delivery_notes_invoiced',
        '${selected.length} bordereau(x) transformé(s) en ${invoice.number}',
        metadata: {
          'delivery_note_numbers': selected.map((note) => note.number).toList(),
          'invoice_number': invoice.number,
        },
      ),
    );
  }

  void _toggleDeliveryNoteSelection() {
    setState(() {
      selectingDeliveryNotes = !selectingDeliveryNotes;
      selectedDeliveryNotes.clear();
    });
  }

  void _selectDeliveryNote(CommercialDocument document) {
    if (selectedDeliveryNotes.isNotEmpty &&
        selectedDeliveryNotes.first.client.toLowerCase() !=
            document.client.toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sélectionnez uniquement les bordereaux du même client.',
          ),
        ),
      );
      return;
    }
    setState(() {
      if (selectedDeliveryNotes.contains(document)) {
        selectedDeliveryNotes.remove(document);
      } else {
        selectedDeliveryNotes.add(document);
      }
    });
  }

  Future<void> _delete(int index) async {
    setState(() => documents.removeAt(index));
    await _save();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Documents commerciaux'),
      actions: [
        if (selectingDeliveryNotes) ...[
          IconButton(
            onPressed: selectedDeliveryNotes.isEmpty
                ? null
                : _createInvoiceFromDeliveryNotes,
            tooltip: 'Créer une facture définitive',
            icon: Badge(
              isLabelVisible: selectedDeliveryNotes.isNotEmpty,
              label: Text('${selectedDeliveryNotes.length}'),
              child: const Icon(Icons.receipt_long_outlined),
            ),
          ),
          IconButton(
            onPressed: _toggleDeliveryNoteSelection,
            tooltip: 'Annuler la sélection',
            icon: const Icon(Icons.close),
          ),
        ] else
          IconButton(
            onPressed:
                documents.any(
                  (document) => document.type == 'Bordereau de livraison',
                )
                ? _toggleDeliveryNoteSelection
                : null,
            tooltip: 'Sélectionner des bordereaux',
            icon: const Icon(Icons.playlist_add_check_outlined),
          ),
        IconButton(
          onPressed: _configureDocumentImages,
          tooltip: 'En-tete et pied de page',
          icon: const Icon(Icons.branding_watermark_outlined),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _create,
      icon: const Icon(Icons.add),
      label: const Text('Nouveau document'),
    ),
    body: documents.isEmpty
        ? const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.description_outlined,
                  size: 65,
                  color: Colors.black26,
                ),
                SizedBox(height: 12),
                Text('Aucun document commercial'),
              ],
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
            itemCount: documents.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final document = documents[index];
              final isDeliveryNote = document.type == 'Bordereau de livraison';
              final isSelected = selectedDeliveryNotes.contains(document);
              return Card(
                child: ListTile(
                  onTap: selectingDeliveryNotes
                      ? (isDeliveryNote
                            ? () => _selectDeliveryNote(document)
                            : null)
                      : () => _actions(document, index),
                  contentPadding: const EdgeInsets.all(14),
                  leading: selectingDeliveryNotes
                      ? Checkbox(
                          value: isSelected,
                          onChanged: isDeliveryNote
                              ? (_) => _selectDeliveryNote(document)
                              : null,
                        )
                      : CircleAvatar(
                          backgroundColor: _green.withValues(alpha: .12),
                          child: const Icon(
                            Icons.description_outlined,
                            color: _green,
                          ),
                        ),
                  title: Text(
                    '${document.type} • ${document.number}',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${document.client}\n${document.createdAt.day.toString().padLeft(2, '0')}/${document.createdAt.month.toString().padLeft(2, '0')}/${document.createdAt.year}',
                  ),
                  isThreeLine: true,
                  trailing: document.type == 'Bordereau de livraison'
                      ? const Text(
                          'Sans montant',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        )
                      : Text(
                          '${money(document.total)} F',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                ),
              );
            },
          ),
  );

  Future<void> _configureDocumentImages() async {
    final prefs = await SharedPreferences.getInstance();
    Uint8List? header = _decodeStoredImage(prefs.getString(_headerImageKey));
    Uint8List? footer = _decodeStoredImage(prefs.getString(_footerImageKey));
    Uint8List? stamp = _decodeStoredImage(prefs.getString(_stampImageKey));
    Uint8List? signature = _decodeStoredImage(
      prefs.getString(_signatureImageKey),
    );
    String template = prefs.getString(_templateKey) ?? 'Classique';
    bool showShopName = prefs.getBool(_showShopNameKey) ?? true;
    double headerHeight = prefs.getDouble(_headerHeightKey) ?? 82;
    double footerHeight = prefs.getDouble(_footerHeightKey) ?? 58;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              18,
              0,
              18,
              18 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Presentation des documents',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Personnalisez les images qui seront placees automatiquement sur vos documents PDF.',
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: template,
                    decoration: const InputDecoration(
                      labelText: 'Modele de document',
                      prefixIcon: Icon(Icons.dashboard_customize_outlined),
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'Classique',
                        child: Text('Classique - vert professionnel'),
                      ),
                      DropdownMenuItem(
                        value: 'Moderne',
                        child: Text('Moderne - bleu dynamique'),
                      ),
                      DropdownMenuItem(
                        value: 'Simple',
                        child: Text('Simple - noir et blanc'),
                      ),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      await prefs.setString(_templateKey, value);
                      setSheetState(() => template = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Afficher le nom de la boutique',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Masquez-le si le nom figure deja dans votre image d\'en-tete.',
                    ),
                    value: showShopName,
                    onChanged: (value) async {
                      await prefs.setBool(_showShopNameKey, value);
                      setSheetState(() => showShopName = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  _documentImageSetting(
                    title: 'Image d\'en-tete',
                    image: header,
                    onImport: () async {
                      final bytes = await _pickDocumentImage();
                      if (bytes == null) return;
                      await prefs.setString(
                        _headerImageKey,
                        base64Encode(bytes),
                      );
                      setSheetState(() => header = bytes);
                    },
                    onRemove: header == null
                        ? null
                        : () async {
                            await prefs.remove(_headerImageKey);
                            setSheetState(() => header = null);
                          },
                  ),
                  if (header != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Hauteur de l\'en-tete : ${headerHeight.round()}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Slider(
                      value: headerHeight,
                      min: 40,
                      max: 170,
                      divisions: 13,
                      label: '${headerHeight.round()}',
                      onChanged: (value) {
                        setSheetState(() => headerHeight = value);
                      },
                      onChangeEnd: (value) async {
                        await prefs.setDouble(_headerHeightKey, value);
                      },
                    ),
                  ],
                  const SizedBox(height: 14),
                  _documentImageSetting(
                    title: 'Image de pied de page',
                    image: footer,
                    onImport: () async {
                      final bytes = await _pickDocumentImage();
                      if (bytes == null) return;
                      await prefs.setString(
                        _footerImageKey,
                        base64Encode(bytes),
                      );
                      setSheetState(() => footer = bytes);
                    },
                    onRemove: footer == null
                        ? null
                        : () async {
                            await prefs.remove(_footerImageKey);
                            setSheetState(() => footer = null);
                          },
                  ),
                  if (footer != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Hauteur du pied de page : ${footerHeight.round()}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Slider(
                      value: footerHeight,
                      min: 30,
                      max: 130,
                      divisions: 10,
                      label: '${footerHeight.round()}',
                      onChanged: (value) {
                        setSheetState(() => footerHeight = value);
                      },
                      onChangeEnd: (value) async {
                        await prefs.setDouble(_footerHeightKey, value);
                      },
                    ),
                  ],
                  const SizedBox(height: 14),
                  _documentImageSetting(
                    title: 'Cachet de la boutique',
                    image: stamp,
                    onImport: () async {
                      final bytes = await _pickDocumentImage();
                      if (bytes == null) return;
                      await prefs.setString(
                        _stampImageKey,
                        base64Encode(bytes),
                      );
                      setSheetState(() => stamp = bytes);
                    },
                    onRemove: stamp == null
                        ? null
                        : () async {
                            await prefs.remove(_stampImageKey);
                            setSheetState(() => stamp = null);
                          },
                  ),
                  const SizedBox(height: 14),
                  _documentImageSetting(
                    title: 'Signature',
                    image: signature,
                    onImport: () async {
                      final bytes = await _pickDocumentImage();
                      if (bytes == null) return;
                      await prefs.setString(
                        _signatureImageKey,
                        base64Encode(bytes),
                      );
                      setSheetState(() => signature = bytes);
                    },
                    onRemove: signature == null
                        ? null
                        : () async {
                            await prefs.remove(_signatureImageKey);
                            setSheetState(() => signature = null);
                          },
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Terminer'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _documentImageSetting({
    required String title,
    required Uint8List? image,
    required Future<void> Function() onImport,
    required Future<void> Function()? onRemove,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          if (image != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(image, height: 90, fit: BoxFit.contain),
            )
          else
            const SizedBox(
              height: 70,
              child: Center(child: Text('Aucune image importee')),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(image == null ? 'Importer' : 'Remplacer'),
                ),
              ),
              if (onRemove != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onRemove,
                  tooltip: 'Supprimer',
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );

  Future<Uint8List?> _pickDocumentImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null) return null;
    final file = result.files.single;
    return file.bytes ??
        (file.path == null ? null : File(file.path!).readAsBytes());
  }

  Uint8List? _decodeStoredImage(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } catch (_) {
      return null;
    }
  }

  void _actions(CommercialDocument document, int index) {
    final nextType = _nextDocumentType(document.type);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '${document.type} ${document.number}',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text('${document.client} • ${money(document.total)} F'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: _green),
              title: const Text('Modifier le document'),
              onTap: () {
                Navigator.pop(sheetContext);
                _edit(document, index);
              },
            ),
            if (document.type == 'Facture définitive' ||
                document.type == 'Facture pro forma')
              ListTile(
                leading: const Icon(Icons.copy_outlined, color: _orange),
                title: const Text('Dupliquer la facture'),
                subtitle: const Text('Créer une nouvelle facture modifiable'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _duplicateInvoice(document);
                },
              ),
            if (nextType != null)
              ListTile(
                leading: const Icon(Icons.upgrade_outlined, color: _orange),
                title: Text('Créer : $nextType'),
                subtitle: const Text('Reprendre le client et les articles'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _evolve(document);
                },
              ),
            ListTile(
              leading: const Icon(Icons.print_outlined, color: _green),
              title: const Text('Imprimer ou enregistrer en PDF'),
              onTap: () {
                Navigator.pop(sheetContext);
                _printDocument(document);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined, color: _green),
              title: const Text('Partager le PDF'),
              onTap: () {
                Navigator.pop(sheetContext);
                _shareDocument(document);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: Color(0xFFD56A4D),
              ),
              title: const Text('Supprimer'),
              onTap: () {
                Navigator.pop(sheetContext);
                _delete(index);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<Uint8List> _pdfBytes(CommercialDocument document) async {
    final prefs = await SharedPreferences.getInstance();
    final shop = prefs.getString('shop_name') ?? 'MONCOMMERCE';
    final phone = prefs.getString('shop_phone') ?? '';
    final address = prefs.getString('shop_address') ?? '';
    final isDeliveryNote = document.type == 'Bordereau de livraison';
    final headerBytes = _decodeStoredImage(prefs.getString(_headerImageKey));
    final footerBytes = _decodeStoredImage(prefs.getString(_footerImageKey));
    final stampBytes = _decodeStoredImage(prefs.getString(_stampImageKey));
    final signatureBytes = _decodeStoredImage(
      prefs.getString(_signatureImageKey),
    );
    final template = prefs.getString(_templateKey) ?? 'Classique';
    final showShopName = prefs.getBool(_showShopNameKey) ?? true;
    final headerHeight = (prefs.getDouble(_headerHeightKey) ?? 82).clamp(
      40.0,
      170.0,
    );
    final footerHeight = (prefs.getDouble(_footerHeightKey) ?? 58).clamp(
      30.0,
      130.0,
    );
    final accentColor = switch (template) {
      'Moderne' => PdfColors.blue700,
      'Simple' => PdfColors.grey800,
      _ => PdfColors.green800,
    };
    final tableHeaderColor = template == 'Simple'
        ? PdfColors.grey200
        : accentColor;
    final tableHeaderTextColor = template == 'Simple'
        ? PdfColors.black
        : PdfColors.white;
    final headerImage = headerBytes == null
        ? null
        : pw.MemoryImage(headerBytes);
    final footerImage = footerBytes == null
        ? null
        : pw.MemoryImage(footerBytes);
    final stampImage = stampBytes == null ? null : pw.MemoryImage(stampBytes);
    final signatureImage = signatureBytes == null
        ? null
        : pw.MemoryImage(signatureBytes);
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        header: headerImage == null
            ? null
            : (context) {
                if (context.pageNumber != 1) return pw.SizedBox();
                return pw.SizedBox(
                  height: headerHeight + 14,
                  child: pw.Transform.translate(
                    offset: const PdfPoint(-36, 0),
                    child: pw.OverflowBox(
                      minWidth: PdfPageFormat.a4.width,
                      maxWidth: PdfPageFormat.a4.width,
                      alignment: pw.Alignment.topLeft,
                      child: pw.SizedBox(
                        width: PdfPageFormat.a4.width,
                        height: headerHeight,
                        child: pw.Center(
                          child: pw.Image(headerImage, fit: pw.BoxFit.contain),
                        ),
                      ),
                    ),
                  ),
                );
              },
        footer: footerImage == null
            ? null
            : (context) {
                final isFirstPageOfMultiPage =
                    context.pagesCount > 1 && context.pageNumber == 1;
                if (isFirstPageOfMultiPage) return pw.SizedBox();
                return pw.SizedBox(
                  height: footerHeight + 10,
                  child: pw.Transform.translate(
                    offset: const PdfPoint(-36, -36),
                    child: pw.OverflowBox(
                      minWidth: PdfPageFormat.a4.width,
                      maxWidth: PdfPageFormat.a4.width,
                      alignment: pw.Alignment.bottomLeft,
                      child: pw.SizedBox(
                        width: PdfPageFormat.a4.width,
                        height: footerHeight,
                        child: pw.Center(
                          child: pw.Image(footerImage, fit: pw.BoxFit.contain),
                        ),
                      ),
                    ),
                  ),
                );
              },
        build: (_) => [
          pw.Container(
            padding: template == 'Moderne'
                ? const pw.EdgeInsets.all(14)
                : pw.EdgeInsets.zero,
            decoration: template == 'Moderne'
                ? pw.BoxDecoration(
                    color: PdfColors.blue50,
                    border: pw.Border(
                      left: pw.BorderSide(color: accentColor, width: 5),
                    ),
                  )
                : null,
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    if (showShopName)
                      pw.Text(
                        shop.toUpperCase(),
                        style: pw.TextStyle(
                          fontSize: 20,
                          color: template == 'Simple' ? null : accentColor,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    if (phone.isNotEmpty) pw.Text('Tel : $phone'),
                    if (address.isNotEmpty) pw.Text(address),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      _pdfType(document.type),
                      style: pw.TextStyle(
                        fontSize: 18,
                        color: template == 'Simple' ? null : accentColor,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text('N ${document.number}'),
                    pw.Text(
                      'Date : ${document.createdAt.day.toString().padLeft(2, '0')}/${document.createdAt.month.toString().padLeft(2, '0')}/${document.createdAt.year}',
                    ),
                    if (document.purchaseOrderNumber.isNotEmpty)
                      pw.Text(
                        'N° Bon de commande : ${document.purchaseOrderNumber}',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 24),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'CLIENT',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
                pw.Text(document.client),
                if (document.phone.isNotEmpty)
                  pw.Text('Tel : ${document.phone}'),
                if (document.address.isNotEmpty) pw.Text(document.address),
              ],
            ),
          ),
          if (document.object.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
              decoration: pw.BoxDecoration(
                color: template == 'Simple' ? null : PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey400),
              ),
              child: pw.RichText(
                text: pw.TextSpan(
                  children: [
                    pw.TextSpan(
                      text: 'OBJET : ',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.TextSpan(text: document.object),
                  ],
                ),
              ),
            ),
          ],
          pw.SizedBox(height: 20),
          pw.TableHelper.fromTextArray(
            headers: isDeliveryNote
                ? const ['Description', 'Quantite livree', 'Observation']
                : const ['Description', 'Qte', 'Prix unitaire', 'Total'],
            data: document.lines
                .map(
                  (line) => isDeliveryNote
                      ? [line.description, '${line.quantity}', line.observation]
                      : [
                          line.description,
                          '${line.quantity}',
                          '${money(line.unitPrice)} F',
                          '${money(line.total)} F',
                        ],
                )
                .toList(),
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              color: tableHeaderTextColor,
            ),
            headerDecoration: pw.BoxDecoration(color: tableHeaderColor),
            border: template == 'Simple'
                ? pw.TableBorder.all(color: PdfColors.grey500, width: .5)
                : null,
            cellPadding: const pw.EdgeInsets.all(8),
          ),
          if (!isDeliveryNote) ...[
            pw.SizedBox(height: 16),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: template == 'Moderne' ? PdfColors.blue50 : null,
                  border: pw.Border.all(color: accentColor, width: 1.5),
                ),
                child: pw.Text(
                  'TOTAL : ${money(document.total)} FCFA',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Arrete le present document a la somme de : ${_amountInWords(document.total)} francs CFA.',
              style: pw.TextStyle(fontSize: 10, fontStyle: pw.FontStyle.italic),
            ),
          ],
          if (document.notes.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            pw.Text('Notes : ${document.notes}'),
          ],
          pw.SizedBox(height: 28),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  children: [
                    pw.Text(
                      'Le Receptionniste',
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 111),
                  ],
                ),
              ),
              pw.SizedBox(width: 28),
              pw.SizedBox(
                width: 190,
                child: pw.Column(
                  children: [
                    pw.Text(
                      'Le Responsable',
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 6),
                    pw.SizedBox(
                      width: 170,
                      height: 105,
                      child: pw.Stack(
                        alignment: pw.Alignment.center,
                        children: [
                          if (stampImage != null)
                            pw.SizedBox(
                              width: 105,
                              height: 100,
                              child: pw.Image(
                                stampImage,
                                fit: pw.BoxFit.contain,
                              ),
                            ),
                          if (signatureImage != null)
                            pw.Transform.translate(
                              offset: const PdfPoint(-28, -6),
                              child: pw.SizedBox(
                                width: 155,
                                height: 75,
                                child: pw.Image(
                                  signatureImage,
                                  fit: pw.BoxFit.contain,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return pdf.save();
  }

  String _pdfType(String type) => switch (type) {
    'Facture pro forma' => 'FACTURE PRO FORMA',
    'Facture définitive' => 'FACTURE DEFINITIVE',
    'Bon de commande' => 'BON DE COMMANDE',
    'Bordereau de livraison' => 'BORDEREAU DE LIVRAISON',
    _ => 'DEVIS',
  };

  String _amountInWords(int amount) {
    if (amount == 0) return 'zero';
    if (amount < 0) return 'moins ${_amountInWords(-amount)}';
    final parts = <String>[];
    void addScale(int value, int scale, String singular, String plural) {
      if (value < scale) return;
      final count = value ~/ scale;
      if (count == 1 && scale == 1000) {
        parts.add(singular);
      } else {
        parts.add('${_underThousand(count)} ${count > 1 ? plural : singular}');
      }
    }

    var rest = amount;
    if (rest >= 1000000000) {
      addScale(rest, 1000000000, 'milliard', 'milliards');
      rest %= 1000000000;
    }
    if (rest >= 1000000) {
      addScale(rest, 1000000, 'million', 'millions');
      rest %= 1000000;
    }
    if (rest >= 1000) {
      addScale(rest, 1000, 'mille', 'mille');
      rest %= 1000;
    }
    if (rest > 0) parts.add(_underThousand(rest));
    return parts.join(' ');
  }

  String _underThousand(int value) {
    if (value < 100) return _underHundred(value);
    final hundreds = value ~/ 100;
    final rest = value % 100;
    final prefix = hundreds == 1 ? 'cent' : '${_underHundred(hundreds)} cent';
    return rest == 0 ? prefix : '$prefix ${_underHundred(rest)}';
  }

  String _underHundred(int value) {
    const units = [
      'zero',
      'un',
      'deux',
      'trois',
      'quatre',
      'cinq',
      'six',
      'sept',
      'huit',
      'neuf',
      'dix',
      'onze',
      'douze',
      'treize',
      'quatorze',
      'quinze',
      'seize',
    ];
    if (value <= 16) return units[value];
    if (value < 20) return 'dix-${units[value - 10]}';
    if (value < 70) {
      const tens = [
        '',
        '',
        'vingt',
        'trente',
        'quarante',
        'cinquante',
        'soixante',
      ];
      final ten = value ~/ 10;
      final unit = value % 10;
      if (unit == 0) return tens[ten];
      return '${tens[ten]}${unit == 1 ? ' et ' : '-'}${units[unit]}';
    }
    if (value < 80) {
      final rest = value - 60;
      return 'soixante${rest == 11 ? ' et ' : '-'}${_underHundred(rest)}';
    }
    final rest = value - 80;
    if (rest == 0) return 'quatre-vingts';
    return 'quatre-vingt-${_underHundred(rest)}';
  }

  Future<void> _printDocument(CommercialDocument document) async =>
      Printing.layoutPdf(
        name: '${document.number}.pdf',
        onLayout: (_) => _pdfBytes(document),
      );

  Future<void> _shareDocument(CommercialDocument document) async =>
      Printing.sharePdf(
        bytes: await _pdfBytes(document),
        filename: '${document.number}.pdf',
      );
}

class CommercialDocumentEditor extends StatefulWidget {
  const CommercialDocumentEditor({
    super.key,
    required this.products,
    required this.customers,
    this.document,
    this.createAsNew = false,
  });
  final List<Product> products;
  final List<CommercialCustomer> customers;
  final CommercialDocument? document;
  final bool createAsNew;

  @override
  State<CommercialDocumentEditor> createState() =>
      _CommercialDocumentEditorState();
}

class _CommercialDocumentEditorState extends State<CommercialDocumentEditor> {
  String type = 'Facture pro forma';
  final client = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final object = TextEditingController();
  final purchaseOrderNumber = TextEditingController();
  final notes = TextEditingController();
  final lines = <CommercialLine>[];

  @override
  void initState() {
    super.initState();
    final document = widget.document;
    if (document == null) return;
    type = document.type;
    client.text = document.client;
    phone.text = document.phone;
    address.text = document.address;
    object.text = document.object;
    purchaseOrderNumber.text = document.purchaseOrderNumber;
    notes.text = document.notes;
    lines.addAll(
      document.lines.map(
        (line) => CommercialLine(
          line.description,
          line.quantity,
          line.unitPrice,
          observation: line.observation,
        ),
      ),
    );
  }

  @override
  void dispose() {
    client.dispose();
    phone.dispose();
    address.dispose();
    object.dispose();
    purchaseOrderNumber.dispose();
    notes.dispose();
    super.dispose();
  }

  String _number(DateTime now) {
    final prefix = switch (type) {
      'Facture pro forma' => 'PRO',
      'Devis' => 'DEV',
      'Facture définitive' => 'FAC',
      'Bordereau de livraison' => 'BL',
      _ => 'BC',
    };
    return '$prefix-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.millisecondsSinceEpoch.toString().substring(8)}';
  }

  Future<CommercialCustomer?> _createCustomer() async {
    final name = TextEditingController();
    final phoneController = TextEditingController();
    final addressController = TextEditingController();
    var isCompany = false;
    final customer = await showDialog<CommercialCustomer>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Nouveau client ou entreprise'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Client')),
                    ButtonSegment(value: true, label: Text('Entreprise')),
                  ],
                  selected: {isCompany},
                  onSelectionChanged: (value) =>
                      setDialogState(() => isCompany = value.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: isCompany
                        ? 'Nom de l’entreprise'
                        : 'Nom du client',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Téléphone'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(labelText: 'Adresse'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                Navigator.pop(
                  dialogContext,
                  CommercialCustomer(
                    name: name.text.trim(),
                    phone: phoneController.text.trim(),
                    address: addressController.text.trim(),
                    isCompany: isCompany,
                  ),
                );
              },
              child: const Text('Utiliser ce contact'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    phoneController.dispose();
    addressController.dispose();
    return customer;
  }

  Future<void> _chooseCustomer() async {
    final customer = await showModalBottomSheet<CommercialCustomer>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Importer un client ou une entreprise',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text('Les coordonnées sont reprises dans le document.'),
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: const Text('Créer un client ou une entreprise'),
              onTap: () => Navigator.pop(
                sheetContext,
                CommercialCustomer(
                  name: '',
                  phone: '',
                  address: '',
                  isCompany: false,
                ),
              ),
            ),
            if (widget.customers.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 8, 18, 18),
                child: Text('Aucun contact enregistré pour le moment.'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.customers.length,
                  itemBuilder: (_, index) {
                    final item = widget.customers[index];
                    return ListTile(
                      leading: Icon(
                        item.isCompany
                            ? Icons.business_outlined
                            : Icons.person_outline,
                      ),
                      title: Text(item.name),
                      subtitle: Text(
                        [
                          item.phone,
                          item.address,
                        ].where((value) => value.isNotEmpty).join(' • '),
                      ),
                      onTap: () => Navigator.pop(sheetContext, item),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
    if (customer == null || !mounted) return;
    final selected = customer.name.isEmpty ? await _createCustomer() : customer;
    if (selected == null || !mounted) return;
    setState(() {
      final alreadyKnown = widget.customers.any(
        (item) => item.name.toLowerCase() == selected.name.toLowerCase(),
      );
      if (!alreadyKnown) widget.customers.add(selected);
      client.text = selected.name;
      phone.text = selected.phone;
      address.text = selected.address;
    });
  }

  Future<void> _addLine([int? editIndex]) async {
    Product? selected;
    final existing = editIndex == null ? null : lines[editIndex];
    final description = TextEditingController(text: existing?.description);
    final quantity = TextEditingController(
      text: existing?.quantity.toString() ?? '1',
    );
    final price = TextEditingController(text: existing?.unitPrice.toString());
    final observation = TextEditingController(text: existing?.observation);
    final line = await showDialog<CommercialLine>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            editIndex == null ? 'Ajouter un article' : 'Modifier l\'article',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<Product?>(
                  isExpanded: true,
                  initialValue: selected,
                  decoration: const InputDecoration(
                    labelText: 'Produit existant (facultatif)',
                  ),
                  items: [
                    const DropdownMenuItem<Product?>(
                      value: null,
                      child: Text('Saisie libre'),
                    ),
                    ...widget.products.map(
                      (product) => DropdownMenuItem<Product?>(
                        value: product,
                        child: Text(product.name),
                      ),
                    ),
                  ],
                  onChanged: (product) {
                    setDialogState(() => selected = product);
                    if (product != null) {
                      description.text = product.name;
                      if (type != 'Bordereau de livraison') {
                        price.text = product.price.toString();
                      }
                    }
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: quantity,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Quantité'),
                ),
                if (type != 'Bordereau de livraison') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: price,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Prix unitaire (FCFA)',
                    ),
                  ),
                ],
                if (type == 'Bordereau de livraison') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: observation,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Observation',
                      hintText: 'Ex. Livré en bon état',
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                final qty = int.tryParse(quantity.text) ?? 0;
                final unitPrice = type == 'Bordereau de livraison'
                    ? existing?.unitPrice ?? 0
                    : int.tryParse(price.text) ?? 0;
                if (description.text.trim().isEmpty || qty < 1) return;
                Navigator.pop(
                  dialogContext,
                  CommercialLine(
                    description.text.trim(),
                    qty,
                    unitPrice,
                    observation: observation.text.trim(),
                  ),
                );
              },
              child: Text(editIndex == null ? 'Ajouter' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (line != null) {
      setState(() {
        if (editIndex == null) {
          lines.add(line);
        } else {
          lines[editIndex] = line;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = lines.fold(0, (sum, line) => sum + line.total);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.document == null || widget.createAsNew
              ? 'Nouveau document'
              : 'Modifier le document',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          DropdownButtonFormField<String>(
            initialValue: type,
            decoration: const InputDecoration(labelText: 'Type de document'),
            items: const [
              DropdownMenuItem(
                value: 'Facture pro forma',
                child: Text('Facture pro forma'),
              ),
              DropdownMenuItem(value: 'Devis', child: Text('Devis')),
              DropdownMenuItem(
                value: 'Facture définitive',
                child: Text('Facture définitive'),
              ),
              DropdownMenuItem(
                value: 'Bon de commande',
                child: Text('Bon de commande'),
              ),
              DropdownMenuItem(
                value: 'Bordereau de livraison',
                child: Text('Bordereau de livraison'),
              ),
            ],
            onChanged: (value) => setState(() => type = value!),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: client,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Nom du client ou entreprise',
              prefixIcon: const Icon(Icons.person_outline),
              suffixIcon: IconButton(
                onPressed: _chooseCustomer,
                tooltip: 'Importer ou créer un contact',
                icon: const Icon(Icons.contacts_outlined),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Téléphone du client'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: address,
            decoration: const InputDecoration(labelText: 'Adresse du client'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: object,
            decoration: const InputDecoration(
              labelText: 'Objet du document',
              prefixIcon: Icon(Icons.subject_outlined),
            ),
          ),
          if (type == 'Facture définitive' ||
              type == 'Bordereau de livraison') ...[
            const SizedBox(height: 10),
            TextField(
              controller: purchaseOrderNumber,
              decoration: const InputDecoration(
                labelText: 'N° du Bon de Commande',
                prefixIcon: Icon(Icons.numbers_outlined),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Articles',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _addLine(),
                icon: const Icon(Icons.add),
                label: const Text('Ajouter'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (lines.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: Text('Ajoutez au moins un article')),
              ),
            )
          else
            ...List.generate(lines.length, (index) {
              final line = lines[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    title: Text(
                      line.description,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      type == 'Bordereau de livraison'
                          ? '${line.quantity} livré(s)${line.observation.isEmpty ? '' : ' • ${line.observation}'}'
                          : '${line.quantity} × ${money(line.unitPrice)} F',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _addLine(index),
                          tooltip: 'Modifier',
                          icon: const Icon(Icons.edit_outlined, color: _green),
                        ),
                        if (type != 'Bordereau de livraison')
                          Text(
                            '${money(line.total)} F',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        IconButton(
                          onPressed: () =>
                              setState(() => lines.removeAt(index)),
                          icon: const Icon(
                            Icons.close,
                            color: Color(0xFFD56A4D),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          const SizedBox(height: 10),
          TextField(
            controller: notes,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Conditions ou notes (facultatif)',
            ),
          ),
          if (type != 'Bordereau de livraison') ...[
            const SizedBox(height: 18),
            Card(
              color: _green.withValues(alpha: .10),
              child: ListTile(
                title: const Text(
                  'TOTAL A PAYER',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                trailing: Text(
                  '${money(total)} FCFA',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: client.text.trim().isEmpty || lines.isEmpty
                  ? null
                  : () {
                      final now = DateTime.now();
                      final existing = widget.document;
                      Navigator.pop(
                        context,
                        CommercialDocument(
                          type: type,
                          number: existing == null || widget.createAsNew
                              ? _number(now)
                              : existing.number,
                          client: client.text.trim(),
                          phone: phone.text.trim(),
                          address: address.text.trim(),
                          object: object.text.trim(),
                          purchaseOrderNumber: purchaseOrderNumber.text.trim(),
                          notes: notes.text.trim(),
                          createdAt: existing == null || widget.createAsNew
                              ? now
                              : existing.createdAt,
                          lines: List.of(lines),
                        ),
                      );
                    },
              icon: const Icon(Icons.save_outlined),
              label: Text(
                widget.document == null || widget.createAsNew
                    ? 'Créer le document'
                    : 'Enregistrer les modifications',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StorefrontSettingsPage extends StatefulWidget {
  const StorefrontSettingsPage({
    super.key,
    required this.products,
    required this.onOpenOrders,
    required this.onPublish,
  });

  final List<Product> products;
  final VoidCallback onOpenOrders;
  final Future<void> Function() onPublish;

  @override
  State<StorefrontSettingsPage> createState() => _StorefrontSettingsPageState();
}

class _StorefrontSettingsPageState extends State<StorefrontSettingsPage> {
  String _link = '';
  bool _loading = true;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _loadLink();
  }

  Future<void> _loadLink() async {
    try {
      final userId = supabase.auth.currentUser!.id;
      var row = await supabase
          .from('profiles')
          .select('store_slug,shop_name')
          .eq('id', userId)
          .single();
      var slug = row['store_slug']?.toString().trim() ?? '';
      if (slug.isEmpty) {
        await supabase
            .from('profiles')
            .update({'store_slug': null})
            .eq('id', userId);
        row = await supabase
            .from('profiles')
            .select('store_slug,shop_name')
            .eq('id', userId)
            .single();
        slug = row['store_slug']?.toString().trim() ?? '';
      }
      if (mounted) {
        setState(() {
          _link = slug.isEmpty
              ? ''
              : Uri.parse(
                  _storefrontBaseUrl,
                ).replace(queryParameters: {'shop': slug}).toString();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _publish() async {
    setState(() => _publishing = true);
    await widget.onPublish();
    if (!mounted) return;
    setState(() => _publishing = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Catalogue web mis à jour.')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Boutique en ligne')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [_dark, _green]),
            borderRadius: BorderRadius.circular(22),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.language_rounded, color: Colors.white, size: 34),
              SizedBox(height: 14),
              Text(
                'Votre catalogue est accessible sur le Web',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 7),
              Text(
                'Le client consulte les articles, remplit son panier et envoie sa commande sans installer l’application.',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Lien public de la boutique',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  _loading
                      ? 'Chargement…'
                      : (_link.isEmpty ? 'Lien indisponible' : _link),
                  style: const TextStyle(color: _green),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _link.isEmpty
                      ? null
                      : () => SharePlus.instance.share(
                          ShareParams(
                            text:
                                'Découvrez nos articles et commandez ici : $_link',
                          ),
                        ),
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Partager le lien'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _link.isEmpty
                      ? null
                      : () => launchUrl(
                          Uri.parse(_link),
                          mode: LaunchMode.externalApplication,
                        ),
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Voir ma boutique'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.inventory_2_outlined),
                ),
                title: Text('${widget.products.length} article(s)'),
                subtitle: const Text(
                  'Publier les prix et stocks actuels sur le catalogue',
                ),
                trailing: _publishing
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded),
                onTap: _publishing ? null : _publish,
              ),
              const Divider(height: 1, indent: 70),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.shopping_bag_outlined),
                ),
                title: const Text('Commandes reçues'),
                subtitle: const Text(
                  'Accepter, refuser ou valider le paiement',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: widget.onOpenOrders,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class OnlineOrdersPage extends StatefulWidget {
  const OnlineOrdersPage({
    super.key,
    required this.products,
    required this.onValidated,
  });

  final List<Product> products;
  final Future<void> Function(Map<String, dynamic>) onValidated;

  @override
  State<OnlineOrdersPage> createState() => _OnlineOrdersPageState();
}

class _OnlineOrdersPageState extends State<OnlineOrdersPage> {
  Future<void> _changeStatus(Map<String, dynamic> order, String status) async {
    try {
      final result = await supabase
          .from('store_orders')
          .update({
            'status': status,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', order['id'])
          .neq('status', 'validated')
          .select();
      if (result.isEmpty) return;
      if (status == 'validated') await widget.onValidated(order);
      unawaited(
        _logActivity(
          'online_order_$status',
          'Commande ${order['order_number']} : $status',
          metadata: {'order_id': order['id'], 'amount': order['total']},
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Action impossible : $error')));
    }
  }

  Future<void> _accept(Map<String, dynamic> order) async {
    final customerPaid = order['customer_paid'] == true;
    await _changeStatus(order, customerPaid ? 'validated' : 'accepted');
  }

  @override
  Widget build(BuildContext context) {
    final userId = supabase.auth.currentUser!.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Commandes en ligne')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: supabase
            .from('store_orders')
            .stream(primaryKey: ['id'])
            .eq('shop_id', userId)
            .order('created_at', ascending: false),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Erreur : ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final orders = snapshot.data!;
          if (orders.isEmpty) {
            return const Center(
              child: Text('Aucune commande reçue pour le moment.'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: orders.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final order = orders[index];
              final items = ((order['items'] as List?) ?? const [])
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList();
              final status = order['status']?.toString() ?? 'pending';
              final paid = order['customer_paid'] == true;
              return Card(
                child: ExpansionTile(
                  initiallyExpanded: status == 'pending',
                  leading: CircleAvatar(
                    backgroundColor: status == 'validated'
                        ? Colors.green.shade100
                        : status == 'rejected'
                        ? Colors.red.shade100
                        : Colors.orange.shade100,
                    child: Icon(
                      status == 'validated'
                          ? Icons.check_rounded
                          : Icons.shopping_bag_outlined,
                      color: status == 'validated' ? _green : _orange,
                    ),
                  ),
                  title: Text(
                    order['order_number']?.toString() ?? 'Commande',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${order['customer_name']} • ${money((order['total'] as num).toInt())} F\n${_orderStatus(status)}${paid ? ' • Paiement déclaré' : ''}',
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    ...items.map(
                      (item) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(item['name']?.toString() ?? 'Article'),
                        subtitle: Text(
                          '${item['quantity']} × ${money((item['unit_price'] as num).toInt())} F',
                        ),
                        trailing: Text(
                          '${money((item['amount'] as num).toInt())} F',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                    const Divider(),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Client : ${order['customer_name']}\nTéléphone : ${order['customer_phone']}\nAdresse : ${order['delivery_address']?.toString().isEmpty == true ? 'Non précisée' : order['delivery_address']}\nPaiement : ${order['payment_method']}',
                      ),
                    ),
                    if ((order['notes']?.toString() ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Note : ${order['notes']}'),
                      ),
                    ],
                    const SizedBox(height: 14),
                    if (status == 'pending')
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _changeStatus(order, 'rejected'),
                              child: const Text('Refuser'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _accept(order),
                              child: Text(
                                paid ? 'Accepter et valider' : 'Accepter',
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (status == 'accepted')
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _changeStatus(order, 'validated'),
                          icon: const Icon(Icons.payments_outlined),
                          label: const Text('Paiement reçu • valider la vente'),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

String _orderStatus(String value) => switch (value) {
  'accepted' => 'Acceptée • paiement attendu',
  'validated' => 'Validée et enregistrée en vente',
  'rejected' => 'Refusée',
  _ => 'En attente',
};

class MorePage extends StatelessWidget {
  const MorePage({
    super.key,
    required this.expenses,
    required this.expenseRecords,
    required this.revenue,
    required this.salesCount,
    required this.credits,
    required this.sales,
    required this.products,
    required this.onExpense,
    required this.onCredit,
    required this.onLogout,
    required this.onDataChanged,
    required this.isSuperAdmin,
    required this.onOpenOnlineOrders,
    required this.onPublishStorefront,
    required this.storageUserId,
    required this.shopName,
  });
  final int expenses;
  final List<ExpenseRecord> expenseRecords;
  final int revenue;
  final int salesCount;
  final List<Credit> credits;
  final List<SaleRecord> sales;
  final List<Product> products;
  final ValueChanged<ExpenseRecord> onExpense;
  final ValueChanged<Credit> onCredit;
  final Future<void> Function() onLogout;
  final Future<void> Function() onDataChanged;
  final bool isSuperAdmin;
  final VoidCallback onOpenOnlineOrders;
  final Future<void> Function() onPublishStorefront;
  final String storageUserId, shopName;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.only(bottom: 25),
    children: [
      const PageHeader('Gestion', 'Toutes les fonctions de votre boutique'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          children: [
            _managementCard(
              context,
              'Dépenses du jour',
              '${money(expenses)} FCFA',
              Icons.payments_outlined,
              const Color(0xFFD56A4D),
              () => _expenseDialog(context),
              onOpen: () => _showExpenses(context),
            ),
            const SizedBox(height: 12),
            _managementCard(
              context,
              'Crédits clients',
              '${credits.length} dossiers • ${money(credits.fold(0, (s, c) => s + c.remaining))} F',
              Icons.people_outline,
              _orange,
              () => _creditDialog(context),
              onOpen: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CreditsPage(credits: credits, onChanged: onDataChanged),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Card(
              child: Column(
                children: [
                  _menu(
                    Icons.language_rounded,
                    'Boutique en ligne',
                    'Partager le catalogue et gérer les commandes',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => StorefrontSettingsPage(
                          products: products,
                          onOpenOrders: onOpenOnlineOrders,
                          onPublish: onPublishStorefront,
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.bar_chart_rounded,
                    'Rapports et statistiques',
                    'Analysez vos performances',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ReportsPage(
                          revenue: revenue,
                          expenses: expenses,
                          salesCount: salesCount,
                          creditTotal: credits.fold(
                            0,
                            (s, c) => s + c.remaining,
                          ),
                          sales: sales,
                          products: products,
                          expenseRecords: expenseRecords,
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.description_outlined,
                    'Documents commerciaux',
                    'Pro forma, devis, factures et commandes',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            CommercialDocumentsPage(products: products),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.local_shipping_outlined,
                    'Fournisseurs',
                    'Gérez vos approvisionnements',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const DirectoryPage(
                          title: 'Fournisseurs',
                          storageKey: 'suppliers_v1',
                          icon: Icons.local_shipping_outlined,
                          nameLabel: 'Nom du fournisseur',
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.account_balance_wallet_outlined,
                    'Dettes fournisseurs',
                    'Crédits reçus et paiements',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const SupplierDebtsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.store_mall_directory_outlined,
                    'Ma boutique',
                    'Informations et réglages',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const ShopSettingsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.people_alt_outlined,
                    'Utilisateurs',
                    'Caissiers et gestionnaires',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LocalStaffPage(
                          shopId: storageUserId,
                          shopName: shopName,
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.cloud_upload_outlined,
                    'Sauvegarde cloud',
                    'Exporter ou restaurer vos données',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const BackupPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.workspace_premium_outlined,
                    'Licence et abonnement',
                    'Formule, activation et expiration',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const LicensePage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.notifications_outlined,
                    'Notifications et mises à jour',
                    'Messages officiels de MonCommerce',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const AnnouncementsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  if (isSuperAdmin) ...[
                    _menu(
                      Icons.monitor_heart_outlined,
                      'Monitoring et journaux',
                      'Présence, actions et erreurs des utilisateurs',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const AdminMonitoringPage(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 65),
                    _menu(
                      Icons.campaign_outlined,
                      'Diffusion aux utilisateurs',
                      'Publier une notification ou une version',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const AdminBroadcastPage(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 65),
                    _menu(
                      Icons.admin_panel_settings_outlined,
                      'Administration des licences',
                      'Créer et révoquer les clés clients',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const SuperAdminLicensesPage(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 65),
                  ],
                  ListTile(
                    leading: const Icon(
                      Icons.logout_rounded,
                      color: Color(0xFFD56A4D),
                    ),
                    title: const Text(
                      'Se déconnecter',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text('Fermer la session de cette boutique'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _confirmLogout(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _managementCard(
    BuildContext context,
    String title,
    String value,
    IconData icon,
    Color color,
    VoidCallback tap, {
    VoidCallback? onOpen,
  }) => Card(
    child: ListTile(
      onTap: onOpen,
      contentPadding: const EdgeInsets.all(15),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: color.withValues(alpha: .12),
        child: Icon(icon, color: color),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(value),
      trailing: FilledButton.tonal(
        onPressed: tap,
        child: const Text('Ajouter'),
      ),
    ),
  );
  Widget _menu(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => ListTile(
    leading: Icon(icon, color: _green),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );

  void _showExpenses(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 5, 22, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Dépenses du jour',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              subtitle: Text('Total cumulé enregistré'),
            ),
            ...expenseRecords
                .take(8)
                .map(
                  (item) => Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.payments_outlined),
                      ),
                      title: Text(
                        item.nature,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(item.createdAt),
                      trailing: Text(
                        '${money(item.amount)} F',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ),
            if (expenseRecords.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('Aucune dépense détaillée enregistrée'),
              ),
          ],
        ),
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Se déconnecter ?'),
        content: const Text(
          'Vos ventes restent enregistrées sur cet appareil.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await onLogout();
            },
            child: const Text('Se déconnecter'),
          ),
        ],
      ),
    );
  }

  void _expenseDialog(BuildContext context) {
    final amount = TextEditingController();
    final nature = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nouvelle dépense'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nature,
              decoration: const InputDecoration(
                labelText: 'Nature de la dépense',
                hintText: 'Transport, loyer, carburant…',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Montant (FCFA)',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              if (nature.text.trim().isEmpty) return;
              final now = DateTime.now();
              onExpense(
                ExpenseRecord(
                  nature.text.trim(),
                  int.tryParse(amount.text) ?? 0,
                  '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                ),
              );
              Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void _creditDialog(BuildContext context) {
    final name = TextEditingController();
    final amount = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nouveau crédit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nom du client'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Montant (FCFA)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.isEmpty) return;
              onCredit(
                Credit(
                  name.text,
                  '',
                  int.tryParse(amount.text) ?? 0,
                  'À définir',
                ),
              );
              Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }
}

class ReportsPage extends StatefulWidget {
  const ReportsPage({
    super.key,
    required this.revenue,
    required this.expenses,
    required this.salesCount,
    required this.creditTotal,
    required this.sales,
    required this.products,
    required this.expenseRecords,
  });
  final int revenue, expenses, salesCount, creditTotal;
  final List<SaleRecord> sales;
  final List<Product> products;
  final List<ExpenseRecord> expenseRecords;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  String period = 'all';

  DateTime? _saleDate(SaleRecord sale) {
    final parts = sale.date.split('/');
    if (parts.length != 3) return null;
    return DateTime.tryParse('${parts[2]}-${parts[1]}-${parts[0]}');
  }

  DateTime get _periodStart {
    final now = DateTime.now();
    return switch (period) {
      'today' => DateTime(now.year, now.month, now.day),
      'week' => DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: now.weekday - 1)),
      'month' => DateTime(now.year, now.month),
      _ => DateTime(2000),
    };
  }

  List<SaleRecord> get _filteredSales => widget.sales.where((sale) {
    final date = _saleDate(sale);
    return period == 'all' || (date != null && !date.isBefore(_periodStart));
  }).toList();

  List<ExpenseRecord> get _filteredExpenses => widget.expenseRecords.where((
    item,
  ) {
    final date = DateTime.tryParse(item.createdAt)?.toLocal();
    return period == 'all' || (date != null && !date.isBefore(_periodStart));
  }).toList();

  @override
  Widget build(BuildContext context) {
    final revenue = _filteredSales.fold(0, (sum, sale) => sum + sale.amount);
    final expenses = _filteredExpenses.fold(
      0,
      (sum, item) => sum + item.amount,
    );
    final salesCount = _filteredSales.length;
    final profit = revenue - expenses;
    final average = salesCount == 0 ? 0 : revenue ~/ salesCount;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rapports et statistiques'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Exporter',
            icon: const Icon(Icons.ios_share_outlined),
            onSelected: (value) =>
                value == 'pdf' ? _exportPdf() : _exportExcel(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pdf', child: Text('Exporter en PDF')),
              PopupMenuItem(value: 'excel', child: Text('Exporter en Excel')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'today', label: Text('Jour')),
              ButtonSegment(value: 'week', label: Text('Semaine')),
              ButtonSegment(value: 'month', label: Text('Mois')),
              ButtonSegment(value: 'all', label: Text('Tout')),
            ],
            selected: {period},
            onSelectionChanged: (value) => setState(() => period = value.first),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_dark, _green]),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'BÉNÉFICE ESTIMÉ',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Text(
                  '${money(profit)} FCFA',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.35,
            children: [
              MetricCard(
                label: 'Chiffre d’affaires',
                value: '${money(revenue)} F',
                icon: Icons.trending_up,
                color: _green,
              ),
              MetricCard(
                label: 'Dépenses',
                value: '${money(expenses)} F',
                icon: Icons.trending_down,
                color: const Color(0xFFD56A4D),
              ),
              MetricCard(
                label: 'Panier moyen',
                value: '${money(average)} F',
                icon: Icons.shopping_basket_outlined,
                color: const Color(0xFF4776B7),
              ),
              MetricCard(
                label: 'Crédits ouverts',
                value: '${money(widget.creditTotal)} F',
                icon: Icons.schedule,
                color: _orange,
              ),
            ],
          ),
          const SizedBox(height: 22),
          SectionTitle('Performance - $_periodLabel'),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  _reportLine('Nombre de ventes', '$salesCount'),
                  const Divider(),
                  _reportLine(
                    'Marge estimée',
                    revenue == 0
                        ? '0 %'
                        : '${((profit / revenue) * 100).toStringAsFixed(1)} %',
                  ),
                  const Divider(),
                  _reportLine('Montant encaissé', '${money(revenue)} FCFA'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const SectionTitle('Exports détaillés'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Rapport PDF'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportExcel,
                  icon: const Icon(Icons.table_view_outlined),
                  label: const Text('Rapport Excel'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _reportLine(String label, String value) => Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(color: Colors.black54)),
      ),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
    ],
  );

  String get _periodLabel => switch (period) {
    'today' => 'Aujourd’hui',
    'week' => 'Cette semaine',
    'month' => 'Ce mois',
    _ => 'Toutes les périodes',
  };

  Future<void> _exportPdf() async {
    final shop =
        (await SharedPreferences.getInstance()).getString('shop_name') ??
        'MonCommerce';
    final revenue = _filteredSales.fold(0, (sum, sale) => sum + sale.amount);
    final expenses = _filteredExpenses.fold(
      0,
      (sum, item) => sum + item.amount,
    );
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (_) => [
          pw.Text(
            shop.toUpperCase(),
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text('RAPPORT D’ACTIVITÉ - $_periodLabel'),
          pw.SizedBox(height: 14),
          pw.Row(
            children: [
              pw.Expanded(child: pw.Text('Ventes : ${_filteredSales.length}')),
              pw.Expanded(
                child: pw.Text('Chiffre d’affaires : ${money(revenue)} FCFA'),
              ),
              pw.Expanded(
                child: pw.Text(
                  'Bénéfice estimé : ${money(revenue - expenses)} FCFA',
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            'VENTES',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headers: const [
              'N° vente',
              'Date',
              'Client',
              'Produits',
              'Paiement',
              'Montant',
            ],
            data: _filteredSales
                .map(
                  (s) => [
                    s.number,
                    '${s.date} ${s.time}',
                    s.client,
                    s.product,
                    s.payment,
                    '${money(s.amount)} F',
                  ],
                )
                .toList(),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.green800),
            headerStyle: pw.TextStyle(
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            'LISTE DES PRODUITS',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headers: const ['Produit', 'Code-barres', 'Prix', 'Quantité'],
            data: widget.products
                .map(
                  (p) => [
                    p.name,
                    p.barcode,
                    '${money(p.price)} F',
                    '${p.stock}',
                  ],
                )
                .toList(),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blue700),
            headerStyle: pw.TextStyle(
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename: 'rapport-moncommerce.pdf',
    );
  }

  Future<void> _exportExcel() async {
    final book = xlsx.Excel.createExcel();
    final summary = book['Résumé'];
    summary.appendRow([
      xlsx.TextCellValue('Rapport MonCommerce'),
      xlsx.TextCellValue(_periodLabel),
    ]);
    final revenue = _filteredSales.fold(0, (sum, sale) => sum + sale.amount);
    final expenses = _filteredExpenses.fold(
      0,
      (sum, item) => sum + item.amount,
    );
    summary.appendRow([
      xlsx.TextCellValue('Nombre de ventes'),
      xlsx.IntCellValue(_filteredSales.length),
    ]);
    summary.appendRow([
      xlsx.TextCellValue('Chiffre d’affaires'),
      xlsx.IntCellValue(revenue),
    ]);
    summary.appendRow([
      xlsx.TextCellValue('Dépenses'),
      xlsx.IntCellValue(expenses),
    ]);
    summary.appendRow([
      xlsx.TextCellValue('Bénéfice estimé'),
      xlsx.IntCellValue(revenue - expenses),
    ]);

    final salesSheet = book['Ventes'];
    salesSheet.appendRow(
      [
        'N° vente',
        'Date',
        'Client',
        'Produits',
        'Paiement',
        'Montant FCFA',
      ].map(xlsx.TextCellValue.new).toList(),
    );
    for (final sale in _filteredSales) {
      salesSheet.appendRow([
        xlsx.TextCellValue(sale.number),
        xlsx.TextCellValue('${sale.date} ${sale.time}'),
        xlsx.TextCellValue(sale.client),
        xlsx.TextCellValue(sale.product),
        xlsx.TextCellValue(sale.payment),
        xlsx.IntCellValue(sale.amount),
      ]);
    }
    final productsSheet = book['Produits'];
    productsSheet.appendRow(
      [
        'Produit',
        'Code-barres',
        'Prix FCFA',
        'Quantité',
      ].map(xlsx.TextCellValue.new).toList(),
    );
    for (final product in widget.products) {
      productsSheet.appendRow([
        xlsx.TextCellValue(product.name),
        xlsx.TextCellValue(product.barcode),
        xlsx.IntCellValue(product.price),
        xlsx.IntCellValue(product.stock),
      ]);
    }
    if (book.tables.containsKey('Sheet1')) book.delete('Sheet1');
    final bytes = book.encode();
    if (bytes == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            Uint8List.fromList(bytes),
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            name: 'rapport-moncommerce.xlsx',
          ),
        ],
        subject: 'Rapport MonCommerce - $_periodLabel',
      ),
    );
  }
}

class CreditsPage extends StatefulWidget {
  const CreditsPage({
    super.key,
    required this.credits,
    required this.onChanged,
  });
  final List<Credit> credits;
  final Future<void> Function() onChanged;
  @override
  State<CreditsPage> createState() => _CreditsPageState();
}

class _CreditsPageState extends State<CreditsPage> {
  Future<void> _markPaid(int index) async {
    final credit = widget.credits[index];
    final controller = TextEditingController(text: credit.remaining.toString());
    final paidAmount = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Paiement du crédit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Reste à payer : ${money(credit.remaining)} FCFA'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Montant payé'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text) ?? 0;
              if (value > 0 && value <= credit.remaining) {
                Navigator.pop(c, value);
              }
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (paidAmount != null) {
      setState(() => credit.paid += paidAmount);
      await widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Crédits clients')),
    body: widget.credits.isEmpty
        ? const Center(child: Text('Aucun crédit en attente'))
        : ListView.separated(
            padding: const EdgeInsets.all(18),
            itemCount: widget.credits.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final credit = widget.credits[index];
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFFFF3D6),
                    child: Icon(Icons.person_outline, color: _orange),
                  ),
                  title: Text(
                    credit.customer,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${credit.phone}\nÉchéance : ${credit.dueDate}',
                  ),
                  isThreeLine: true,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${money(credit.remaining)} F',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      if (credit.remaining > 0)
                        TextButton(
                          onPressed: () => _markPaid(index),
                          child: const Text('Payer'),
                        )
                      else
                        const Text(
                          'Réglé',
                          style: TextStyle(
                            color: _green,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

class DirectoryPage extends StatefulWidget {
  const DirectoryPage({
    super.key,
    required this.title,
    required this.storageKey,
    required this.icon,
    required this.nameLabel,
    this.enableRoles = false,
  });
  final String title, storageKey, nameLabel;
  final IconData icon;
  final bool enableRoles;
  @override
  State<DirectoryPage> createState() => _DirectoryPageState();
}

class _DirectoryPageState extends State<DirectoryPage> {
  final List<Map<String, String>> _items = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(widget.storageKey);
    if (raw == null || !mounted) return;
    final decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    setState(
      () => _items.addAll(
        decoded.map(
          (item) => item.map((key, value) => MapEntry(key, value.toString())),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(widget.storageKey, jsonEncode(_items));
  }

  void _add() {
    final name = TextEditingController();
    final phone = TextEditingController();
    final detail = TextEditingController();
    var selectedRole = 'Caissier';
    var isActive = true;
    showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Ajouter • ${widget.title}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(labelText: widget.nameLabel),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Téléphone'),
              ),
              const SizedBox(height: 10),
              if (widget.enableRoles) ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Rôle de l’utilisateur',
                    prefixIcon: Icon(Icons.admin_panel_settings_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'Caissier',
                      child: Text('Caissier • ventes et caisse'),
                    ),
                    DropdownMenuItem(
                      value: 'Vendeur',
                      child: Text('Vendeur • ventes et clients'),
                    ),
                    DropdownMenuItem(
                      value: 'Gestionnaire',
                      child: Text('Gestionnaire • stock et rapports'),
                    ),
                    DropdownMenuItem(
                      value: 'Administrateur',
                      child: Text('Administrateur • accès complet'),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => selectedRole = value!),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isActive,
                  onChanged: (value) => setDialogState(() => isActive = value),
                  title: const Text('Compte actif'),
                  subtitle: const Text('Autoriser cet utilisateur'),
                ),
              ] else
                TextField(
                  controller: detail,
                  decoration: const InputDecoration(
                    labelText: 'Rôle ou spécialité',
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                setState(
                  () => _items.add({
                    'name': name.text.trim(),
                    'phone': phone.text.trim(),
                    'detail': widget.enableRoles
                        ? selectedRole
                        : detail.text.trim(),
                    'active': isActive.toString(),
                  }),
                );
                _save();
                Navigator.pop(c);
              },
              child: const Text('Ajouter'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _add,
      icon: const Icon(Icons.add),
      label: const Text('Ajouter'),
    ),
    body: _items.isEmpty
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 55, color: Colors.black26),
                const SizedBox(height: 12),
                Text('Aucun élément dans ${widget.title.toLowerCase()}'),
              ],
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
            itemCount: _items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final item = _items[index];
              final active = item['active'] != 'false';
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: active
                        ? _green.withValues(alpha: .12)
                        : Colors.black12,
                    child: Icon(
                      widget.icon,
                      color: active ? _green : Colors.black38,
                    ),
                  ),
                  title: Text(
                    item['name']!,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: active ? null : Colors.black45,
                    ),
                  ),
                  subtitle: Text(
                    widget.enableRoles
                        ? '${item['phone']} • ${item['detail']} • ${active ? 'Actif' : 'Désactivé'}'
                        : '${item['phone']} • ${item['detail']}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'toggle') {
                        setState(() => item['active'] = (!active).toString());
                      } else if (action == 'delete') {
                        setState(() => _items.removeAt(index));
                      }
                      _save();
                    },
                    itemBuilder: (_) => [
                      if (widget.enableRoles)
                        PopupMenuItem(
                          value: 'toggle',
                          child: Text(active ? 'Désactiver' : 'Activer'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Supprimer'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

class SupplierDebtsPage extends StatefulWidget {
  const SupplierDebtsPage({super.key});
  @override
  State<SupplierDebtsPage> createState() => _SupplierDebtsPageState();
}

class _SupplierDebtsPageState extends State<SupplierDebtsPage> {
  final List<Map<String, dynamic>> debts = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('supplier_debts_v1');
    if (raw != null && mounted) {
      setState(
        () => debts.addAll(
          List<Map<String, dynamic>>.from(jsonDecode(raw) as List),
        ),
      );
    }
  }

  Future<void> _save() async => (await SharedPreferences.getInstance())
      .setString('supplier_debts_v1', jsonEncode(debts));

  void _add() {
    final supplier = TextEditingController();
    final amount = TextEditingController();
    final nature = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nouvelle dette fournisseur'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: supplier,
              decoration: const InputDecoration(labelText: 'Fournisseur'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nature,
              decoration: const InputDecoration(
                labelText: 'Marchandise ou motif',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Montant dû'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              if (supplier.text.isEmpty) return;
              setState(
                () => debts.insert(0, {
                  'supplier': supplier.text.trim(),
                  'nature': nature.text.trim(),
                  'amount': int.tryParse(amount.text) ?? 0,
                  'paid': 0,
                }),
              );
              _save();
              Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void _pay(int index) {
    final remaining =
        (debts[index]['amount'] as int) - (debts[index]['paid'] as int);
    final value = TextEditingController(text: remaining.toString());
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Paiement fournisseur'),
        content: TextField(
          controller: value,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Montant payé',
            helperText: 'Reste : ${money(remaining)} F',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final paid = int.tryParse(value.text) ?? 0;
              if (paid <= 0 || paid > remaining) return;
              setState(
                () =>
                    debts[index]['paid'] = (debts[index]['paid'] as int) + paid,
              );
              _save();
              Navigator.pop(c);
            },
            child: const Text('Payer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Dettes fournisseurs')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _add,
      icon: const Icon(Icons.add),
      label: const Text('Ajouter'),
    ),
    body: debts.isEmpty
        ? const Center(child: Text('Aucune dette fournisseur'))
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
            itemCount: debts.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final item = debts[index];
              final remaining = (item['amount'] as int) - (item['paid'] as int);
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.local_shipping_outlined),
                  ),
                  title: Text(
                    item['supplier'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${item['nature']}\nPayé : ${money(item['paid'] as int)} F',
                  ),
                  isThreeLine: true,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${money(remaining)} F',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      if (remaining > 0)
                        TextButton(
                          onPressed: () => _pay(index),
                          child: const Text('Payer'),
                        )
                      else
                        const Text('Réglé', style: TextStyle(color: _green)),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

class ShopSettingsPage extends StatefulWidget {
  const ShopSettingsPage({super.key});
  @override
  State<ShopSettingsPage> createState() => _ShopSettingsPageState();
}

class _ShopSettingsPageState extends State<ShopSettingsPage> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final city = TextEditingController();
  double? latitude;
  double? longitude;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    name.text = prefs.getString('shop_name') ?? '';
    phone.text = prefs.getString('shop_phone') ?? '';
    address.text = prefs.getString('shop_address') ?? '';
    city.text = prefs.getString('shop_city') ?? '';
    if (mounted) {
      setState(() {
        latitude = prefs.getDouble('shop_latitude');
        longitude = prefs.getDouble('shop_longitude');
      });
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('shop_name', name.text.trim());
    await prefs.setString('shop_phone', phone.text.trim());
    await prefs.setString('shop_address', address.text.trim());
    await prefs.setString('shop_city', city.text.trim());
    if (latitude != null) await prefs.setDouble('shop_latitude', latitude!);
    if (longitude != null) await prefs.setDouble('shop_longitude', longitude!);
    final userId = supabase.auth.currentUser?.id;
    if (userId != null) {
      await supabase
          .from('profiles')
          .update({
            'shop_name': name.text.trim(),
            'phone': phone.text.trim(),
            'city': city.text.trim(),
          })
          .eq('id', userId);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Informations de la boutique enregistrées')),
    );
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    address.dispose();
    city.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Autorisez la localisation dans les réglages.'),
          ),
        );
      }
      return;
    }
    final position = await Geolocator.getCurrentPosition();
    if (!mounted) return;
    setState(() {
      latitude = position.latitude;
      longitude = position.longitude;
    });
  }

  Future<void> _openMap() async {
    if (latitude == null || longitude == null) return;
    await launchUrl(
      Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude',
      ),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ma boutique')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Center(
          child: CircleAvatar(
            radius: 42,
            backgroundColor: _green,
            child: Icon(Icons.storefront, size: 42, color: Colors.white),
          ),
        ),
        const SizedBox(height: 25),
        const ReceiptPrintSettingsCard(),
        const SizedBox(height: 20),
        TextField(
          controller: name,
          decoration: const InputDecoration(
            labelText: 'Nom commercial',
            prefixIcon: Icon(Icons.store_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Téléphone',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: address,
          decoration: const InputDecoration(
            labelText: 'Adresse',
            prefixIcon: Icon(Icons.location_on_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: city,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Ville',
            hintText: 'Ex. Ouagadougou, Bobo-Dioulasso',
            prefixIcon: Icon(Icons.location_city_outlined),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE1F1EA),
              child: Icon(Icons.map_outlined, color: _green),
            ),
            title: Text(
              latitude == null
                  ? 'Localisation non définie'
                  : '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text('Position GPS de la boutique'),
            onTap: latitude == null ? _locate : _openMap,
            trailing: IconButton(
              onPressed: _locate,
              icon: const Icon(Icons.my_location),
            ),
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Enregistrer les modifications'),
          ),
        ),
      ],
    ),
  );
}

class SuperAdminLicensesPage extends StatefulWidget {
  const SuperAdminLicensesPage({super.key});
  @override
  State<SuperAdminLicensesPage> createState() => _SuperAdminLicensesPageState();
}

class _SuperAdminLicensesPageState extends State<SuperAdminLicensesPage> {
  List<Map<String, dynamic>> _licenses = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await supabase
        .from('licenses')
        .select(
          'id, key_hint, plan, duration_days, status, activated_at, expires_at, created_at',
        )
        .order('created_at', ascending: false);
    if (!mounted) return;
    setState(() {
      _licenses = List<Map<String, dynamic>>.from(rows);
      _loading = false;
    });
  }

  Future<void> _create(String plan) async {
    try {
      final result = await supabase.rpc(
        'create_license',
        params: {
          'p_plan': plan,
          'p_duration_days': plan == 'pro_annual' ? 365 : 30,
        },
      );
      final row = (result as List).first as Map<String, dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          title: const Text('Licence créée'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Copiez ou partagez cette clé maintenant. Elle ne sera plus affichée en entier.',
              ),
              const SizedBox(height: 16),
              SelectableText(
                row['license_key'] as String,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => SharePlus.instance.share(
                ShareParams(
                  text: 'Votre licence MonCommerce : ${row['license_key']}',
                ),
              ),
              child: const Text('Partager'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Terminé'),
            ),
          ],
        ),
      );
      await _load();
    } on PostgrestException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _revoke(String id) async {
    await supabase.rpc('revoke_license', params: {'p_license_id': id});
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Administration des licences')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (c) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text(
                    'Créer une licence',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_month, color: _green),
                  title: const Text('Standard mensuel'),
                  subtitle: const Text('Valable 30 jours'),
                  onTap: () {
                    Navigator.pop(c);
                    _create('standard_monthly');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.workspace_premium, color: _orange),
                  title: const Text('Pro annuel'),
                  subtitle: const Text('Valable 365 jours'),
                  onTap: () {
                    Navigator.pop(c);
                    _create('pro_annual');
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      icon: const Icon(Icons.add),
      label: const Text('Créer'),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _licenses.isEmpty
        ? const Center(child: Text('Aucune licence créée'))
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
              itemCount: _licenses.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, index) {
                final item = _licenses[index];
                final status = item['status'] as String;
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(14),
                    leading: CircleAvatar(
                      backgroundColor: status == 'active'
                          ? const Color(0xFFE1F1EA)
                          : const Color(0xFFFFF3D6),
                      child: Icon(
                        status == 'active' ? Icons.verified : Icons.key,
                        color: status == 'active' ? _green : _orange,
                      ),
                    ),
                    title: Text(
                      'MC-••••-${item['key_hint']}',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    subtitle: Text(
                      '${item['plan'] == 'pro_annual' ? 'Pro annuel' : 'Standard mensuel'} • $status',
                    ),
                    trailing: status == 'revoked'
                        ? const Text(
                            'Révoquée',
                            style: TextStyle(color: Colors.black45),
                          )
                        : IconButton(
                            tooltip: 'Révoquer',
                            onPressed: () => _revoke(item['id'] as String),
                            icon: const Icon(
                              Icons.block,
                              color: Color(0xFFD56A4D),
                            ),
                          ),
                  ),
                );
              },
            ),
          ),
  );
}

class LicensePage extends StatefulWidget {
  const LicensePage({super.key});
  @override
  State<LicensePage> createState() => _LicensePageState();
}

class _LicensePageState extends State<LicensePage> {
  final _keyController = TextEditingController();
  String _plan = 'Essai gratuit';
  String _selectedPlan = 'Standard mensuel';
  String _licenseKey = '';
  DateTime? _expiresAt;
  bool _loading = true;
  bool _usingCachedLicense = false;

  bool get _active => _expiresAt != null && _expiresAt!.isAfter(DateTime.now());
  int get _daysLeft {
    if (!_active) return 0;
    final difference = _expiresAt!.difference(DateTime.now());
    return difference.inDays + (difference.inHours % 24 > 0 ? 1 : 0);
  }

  @override
  void initState() {
    super.initState();
    _loadLicense();
  }

  Future<void> _loadLicense() async {
    Map<String, dynamic>? row;
    var usingCache = false;
    try {
      final rows = await supabase
          .from('licenses')
          .select('plan, status, key_hint, expires_at')
          .order('created_at', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 5));
      row = rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
      unawaited(_cacheLicenseVerification());
    } catch (_) {
      row = await _cachedLicense();
      usingCache = true;
    }
    if (!mounted) return;
    setState(() {
      _plan = row == null
          ? 'Aucune licence'
          : row['plan'] == 'pro_annual'
          ? 'Pro annuel'
          : 'Standard mensuel';
      _licenseKey = row == null ? '' : '••••-${row['key_hint']}';
      _expiresAt = row == null || row['expires_at'] == null
          ? null
          : DateTime.tryParse(row['expires_at'] as String)?.toLocal();
      _usingCachedLicense = usingCache;
      _loading = false;
    });
  }

  Future<void> _activate() async {
    final key = _keyController.text.trim().toUpperCase();
    if (!RegExp(r'^MC-[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(key)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Clé invalide. Format attendu : MC-XXXX-XXXX'),
        ),
      );
      return;
    }
    try {
      await supabase.rpc('activate_license', params: {'p_license_key': key});
      _keyController.clear();
      await _loadLicense();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Licence activée avec succès.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is PostgrestException
                ? error.message
                : 'Connexion Internet requise pour activer une licence.',
          ),
        ),
      );
    }
  }

  String _date(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Licence et abonnement')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: _active
                        ? const [_dark, _green]
                        : const [Color(0xFF7D3428), Color(0xFFD56A4D)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _active
                              ? Icons.verified_rounded
                              : Icons.error_outline,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _active ? 'LICENCE ACTIVE' : 'LICENCE EXPIRÉE',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .7,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      _plan,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 25,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _active
                          ? '$_daysLeft jour(s) restant(s) • expire le ${_date(_expiresAt!)}'
                          : 'Renouvelez votre licence pour continuer',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    if (_licenseKey.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Clé : $_licenseKey',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_usingCachedLicense) ...[
                const SizedBox(height: 12),
                const Text(
                  'Informations affichées depuis la dernière vérification en ligne.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
              const SizedBox(height: 25),
              const SectionTitle('Choisir une formule'),
              const SizedBox(height: 12),
              _planTile(
                'Standard mensuel',
                'Ventes, stock, crédits et rapports',
                '3 000 FCFA / mois',
              ),
              const SizedBox(height: 10),
              _planTile(
                'Pro annuel',
                'Toutes les fonctions et sauvegardes',
                '30 000 FCFA / an',
              ),
              const SizedBox(height: 24),
              const SectionTitle('Activer une clé'),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Clé de licence',
                  hintText: 'MC-XXXX-XXXX',
                  prefixIcon: Icon(Icons.key_outlined),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: _activate,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Activer la licence'),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'La clé est vérifiée de façon sécurisée sur le serveur MonCommerce. Une clé ne peut être attribuée qu’à un seul compte.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ],
          ),
  );

  Widget _planTile(String plan, String description, String price) => Card(
    child: ListTile(
      onTap: () => setState(() => _selectedPlan = plan),
      leading: Icon(
        _selectedPlan == plan
            ? Icons.radio_button_checked
            : Icons.radio_button_off,
        color: _selectedPlan == plan ? _green : Colors.black38,
      ),
      title: Text(plan, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text('$description\n$price'),
      isThreeLine: true,
      trailing: _selectedPlan == plan
          ? const Icon(Icons.check_circle, color: _green)
          : null,
    ),
  );
}

class BarcodeScannerPage extends StatefulWidget {
  const BarcodeScannerPage({super.key});
  @override
  State<BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends State<BarcodeScannerPage> {
  bool _returned = false;
  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return const WindowsBarcodeEntryPage();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scanner le produit'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_returned || capture.barcodes.isEmpty) return;
              final value = capture.barcodes.first.rawValue;
              if (value == null || value.isEmpty) return;
              _returned = true;
              Navigator.pop(context, value);
            },
          ),
          Center(
            child: Container(
              width: 260,
              height: 150,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          const Positioned(
            left: 30,
            right: 30,
            bottom: 45,
            child: Text(
              'Placez le code-barres dans le cadre',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ContinuousBarcodeScannerPage extends StatefulWidget {
  const ContinuousBarcodeScannerPage({super.key});

  @override
  State<ContinuousBarcodeScannerPage> createState() =>
      _ContinuousBarcodeScannerPageState();
}

class _ContinuousBarcodeScannerPageState
    extends State<ContinuousBarcodeScannerPage> {
  final scannedCodes = <String>[];
  final lastDetection = <String, DateTime>{};

  void _detect(BarcodeCapture capture) {
    final now = DateTime.now();
    var changed = false;
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue;
      if (code == null || code.isEmpty) continue;
      final previous = lastDetection[code];
      if (previous != null && now.difference(previous).inMilliseconds < 1200) {
        continue;
      }
      lastDetection[code] = now;
      scannedCodes.add(code);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return const WindowsContinuousBarcodeEntryPage();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Vente rapide - scan continu'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          TextButton.icon(
            onPressed: scannedCodes.isEmpty
                ? null
                : () => Navigator.pop(context, scannedCodes),
            icon: const Icon(Icons.check, color: Colors.white),
            label: const Text(
              'Terminer',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(onDetect: _detect),
          Center(
            child: Container(
              width: 275,
              height: 165,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 35,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  Text(
                    '${scannedCodes.length} produit(s) scanné(s)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Scannez les produits à la suite, puis touchez Terminer.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class WindowsCameraPreview extends StatefulWidget {
  const WindowsCameraPreview({super.key});

  @override
  State<WindowsCameraPreview> createState() => _WindowsCameraPreviewState();
}

class _WindowsCameraPreviewState extends State<WindowsCameraPreview> {
  CameraController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('Aucune webcam détectée.');
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: CameraPreview(controller),
        ),
      );
    }
    return Container(
      height: 230,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF17231D),
        borderRadius: BorderRadius.circular(18),
      ),
      child: _error == null
          ? const CircularProgressIndicator(color: Colors.white)
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Webcam indisponible. Vérifiez les autorisations de caméra dans les Paramètres Windows.\n\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
    );
  }
}

class WindowsBarcodeEntryPage extends StatefulWidget {
  const WindowsBarcodeEntryPage({super.key});

  @override
  State<WindowsBarcodeEntryPage> createState() =>
      _WindowsBarcodeEntryPageState();
}

class _WindowsBarcodeEntryPageState extends State<WindowsBarcodeEntryPage> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = _code.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scanner le produit')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const WindowsCameraPreview(),
            const SizedBox(height: 20),
            const Text(
              'Webcam activée',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            const Text(
              'La lecture automatique des codes-barres n’est pas prise en charge par Windows. Saisissez le code ou utilisez un lecteur USB : il remplit ce champ automatiquement.',
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _code,
              autofocus: true,
              onSubmitted: (_) => _confirm(),
              decoration: const InputDecoration(
                labelText: 'Code-barres',
                prefixIcon: Icon(Icons.qr_code_rounded),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _confirm,
              icon: const Icon(Icons.check),
              label: const Text('Utiliser ce code'),
            ),
          ],
        ),
      ),
    ),
  );
}

class WindowsContinuousBarcodeEntryPage extends StatefulWidget {
  const WindowsContinuousBarcodeEntryPage({super.key});

  @override
  State<WindowsContinuousBarcodeEntryPage> createState() =>
      _WindowsContinuousBarcodeEntryPageState();
}

class _WindowsContinuousBarcodeEntryPageState
    extends State<WindowsContinuousBarcodeEntryPage> {
  final _code = TextEditingController();
  final _codes = <String>[];

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _add() {
    final value = _code.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _codes.add(value);
      _code.clear();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Vente rapide - saisie des codes'),
      actions: [
        TextButton.icon(
          onPressed: _codes.isEmpty
              ? null
              : () => Navigator.pop(context, _codes),
          icon: const Icon(Icons.check),
          label: const Text('Terminer'),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const WindowsCameraPreview(),
            const SizedBox(height: 16),
            Text(
              '${_codes.length} produit(s) ajouté(s)',
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            const Text(
              'Utilisez la webcam pour vous guider, puis saisissez le code ou utilisez votre lecteur de code-barres USB.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              autofocus: true,
              onSubmitted: (_) => _add(),
              decoration: InputDecoration(
                labelText: 'Code-barres',
                prefixIcon: const Icon(Icons.qr_code_rounded),
                suffixIcon: IconButton(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                ),
              ),
            ),
            if (_codes.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _codes
                    .map((code) => Chip(label: Text(code)))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class DesktopCameraCapturePage extends StatefulWidget {
  const DesktopCameraCapturePage({super.key});

  @override
  State<DesktopCameraCapturePage> createState() =>
      _DesktopCameraCapturePageState();
}

class _DesktopCameraCapturePageState extends State<DesktopCameraCapturePage> {
  CameraController? _controller;
  String? _error;
  bool _takingPhoto = false;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('Aucune webcam détectée.');
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _takingPhoto)
      return;
    setState(() => _takingPhoto = true);
    try {
      final photo = await controller.takePicture();
      if (mounted) Navigator.pop(context, photo.path);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Impossible de prendre la photo : $error')),
        );
    } finally {
      if (mounted) setState(() => _takingPhoto = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Prendre une photo')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: controller != null && controller.value.isInitialized
              ? AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: CameraPreview(controller),
                )
              : Text(
                  _error == null
                      ? 'Activation de la webcam…'
                      : 'Webcam indisponible.\n\n$_error',
                  textAlign: TextAlign.center,
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _takingPhoto ? null : _takePhoto,
        icon: const Icon(Icons.camera_alt_outlined),
        label: Text(_takingPhoto ? 'Capture…' : 'Prendre la photo'),
      ),
    );
  }
}

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;
  static const _keys = [
    'moncommerce_data_v1',
    'shop_name',
    'shop_phone',
    'shop_address',
    'shop_city',
    'suppliers_v1',
    'users_v1',
    'license_plan',
    'license_key',
    'license_expiry',
  ];

  Future<void> _export() async {
    setState(() => _busy = true);
    final prefs = await SharedPreferences.getInstance();
    final data = <String, dynamic>{
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
    };
    for (final key in _keys) {
      data[key] = prefs.get(key);
    }
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            bytes,
            mimeType: 'application/json',
            name: 'moncommerce-sauvegarde.json',
          ),
        ],
        subject: 'Sauvegarde MonCommerce',
        text: 'Sauvegarde de ma boutique MonCommerce',
      ),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restore() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return;
    try {
      final data =
          jsonDecode(utf8.decode(result.files.single.bytes!))
              as Map<String, dynamic>;
      final prefs = await SharedPreferences.getInstance();
      for (final key in _keys) {
        final value = data[key];
        if (value is String) await prefs.setString(key, value);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sauvegarde restaurée. Redémarrez l’application.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ce fichier de sauvegarde est invalide.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sauvegarde cloud')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.cloud_done_outlined, size: 75, color: _green),
        const SizedBox(height: 18),
        const Text(
          'Protégez les données de votre boutique',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        const Text(
          'Exportez votre sauvegarde vers Google Drive, OneDrive, WhatsApp ou tout autre service disponible sur le téléphone.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 28),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE1F1EA),
              child: Icon(Icons.cloud_upload_outlined, color: _green),
            ),
            title: const Text(
              'Créer une sauvegarde',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text('Ventes, produits, crédits et réglages'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _export,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFFFF3D6),
              child: Icon(Icons.restore, color: _orange),
            ),
            title: const Text(
              'Restaurer une sauvegarde',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text('Sélectionner un fichier MonCommerce JSON'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _restore,
          ),
        ),
      ],
    ),
  );
}

class SaleSheet extends StatefulWidget {
  const SaleSheet({
    super.key,
    required this.products,
    required this.onValidated,
  });
  final List<Product> products;
  final FutureOr<void> Function(List<SaleLine>, String, String) onValidated;
  @override
  State<SaleSheet> createState() => _SaleSheetState();
}

class _SaleSheetState extends State<SaleSheet> {
  String payment = 'Espèces';
  final List<SaleLine> cart = [];
  final clientController = TextEditingController();
  final productSearchController = TextEditingController();
  final barcodeController = TextEditingController();
  final barcodeFocus = FocusNode();
  String scanMessage = 'Lecteur USB : scannez un produit pour l’ajouter.';
  bool scanError = false;
  String keyboardBarcode = '';
  DateTime? lastBarcodeKey;
  Timer? barcodeTimer;
  Timer? hardwareBarcodeTimer;
  TextEditingController? scanTextController;
  TextEditingValue? textBeforeScan;
  ReceiptPrintSettings printSettings = const ReceiptPrintSettings();
  bool validating = false;

  @override
  void initState() {
    super.initState();
    _loadPrintSettings();
    HardwareKeyboard.instance.addHandler(_captureHardwareBarcode);
  }

  Future<void> _loadPrintSettings() async {
    try {
      final saved = await ReceiptPrintSettings.load();
      if (mounted) setState(() => printSettings = saved);
    } catch (_) {
      // Printing reports configuration failures independently after saving.
    }
  }

  Future<void> _configurePrinting() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Impression du ticket'),
        content: const SizedBox(
          width: 480,
          child: SingleChildScrollView(child: ReceiptPrintSettingsCard()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Terminé'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await _loadPrintSettings();
    if (mounted) barcodeFocus.requestFocus();
  }

  void _submitBarcode(String value) {
    barcodeTimer?.cancel();
    hardwareBarcodeTimer?.cancel();
    keyboardBarcode = '';
    if (validating || !mounted || ModalRoute.of(context)?.isCurrent != true)
      return;
    final code = value.trim();
    if (code.isEmpty) return;
    final matches = widget.products
        .where((p) => p.barcode.trim() == code)
        .toList();
    setState(() {
      scanError = true;
      if (matches.isEmpty) {
        scanMessage = 'Code inconnu : $code';
      } else if (matches.length > 1) {
        scanMessage = 'Code attribué à plusieurs produits : $code';
      } else if (_quantityInCart(matches.single) >= matches.single.stock) {
        scanMessage = 'Stock insuffisant : ${matches.single.name}';
      } else {
        _addProduct(matches.single);
        scanError = false;
        scanMessage =
            '${matches.single.name} ajouté • quantité ${_quantityInCart(matches.single)}';
      }
      barcodeController.clear();
    });
    barcodeFocus.requestFocus();
  }

  void _barcodeChanged(String value) {
    barcodeTimer?.cancel();
    final code = value.trim();
    if (code.isEmpty) return;
    // USB readers without a suffix finish by pausing. Match the whole code,
    // preserving leading zeroes and keeping incomplete manual input editable.
    barcodeTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || validating || ModalRoute.of(context)?.isCurrent != true)
        return;
      if (widget.products.any((p) => p.barcode.trim() == code)) {
        _submitBarcode(code);
      } else {
        setState(() {
          scanError = true;
          scanMessage = 'Code non reconnu : $code';
        });
      }
    });
  }

  bool _captureHardwareBarcode(KeyEvent event) {
    if (event is! KeyDownEvent ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true)
      return false;
    if (validating) return true;
    if (barcodeFocus.hasFocus)
      return false; // The scanner field also handles pasted input.
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed)
      return false;
    final now = DateTime.now();
    if (lastBarcodeKey == null ||
        now.difference(lastBarcodeKey!) > const Duration(milliseconds: 100)) {
      keyboardBarcode = '';
      final focusContext = FocusManager.instance.primaryFocus?.context;
      final editable = focusContext
          ?.findAncestorWidgetOfExactType<EditableText>();
      final controller = editable?.controller;
      scanTextController =
          [clientController, productSearchController].contains(controller)
          ? controller
          : null;
      textBeforeScan = scanTextController?.value;
    }
    lastBarcodeKey = now;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      return _finishHardwareBarcode();
    }
    if (event.character != null &&
        event.character!.codeUnits.every((c) => c >= 32) &&
        keyboardBarcode.length < 128) {
      keyboardBarcode += event.character!;
      hardwareBarcodeTimer?.cancel();
      hardwareBarcodeTimer = Timer(const Duration(milliseconds: 200), () {
        _finishHardwareBarcode();
        keyboardBarcode = '';
        lastBarcodeKey = null;
      });
    }
    return false;
  }

  bool _finishHardwareBarcode() {
    if (!mounted ||
        validating ||
        ModalRoute.of(context)?.isCurrent != true ||
        keyboardBarcode.length < 3)
      return false;
    final code = keyboardBarcode;
    final known = widget.products.any((p) => p.barcode.trim() == code);
    // Do not interpret ordinary names typed in customer/search fields as scans.
    if (!known &&
        scanTextController != null &&
        !RegExp(r'^\d{6,}$').hasMatch(code))
      return false;
    if (scanTextController != null && textBeforeScan != null)
      scanTextController!.value = textBeforeScan!;
    scanTextController = null;
    textBeforeScan = null;
    _submitBarcode(code);
    return true;
  }

  @override
  void dispose() {
    barcodeTimer?.cancel();
    hardwareBarcodeTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_captureHardwareBarcode);
    clientController.dispose();
    productSearchController.dispose();
    barcodeController.dispose();
    barcodeFocus.dispose();
    super.dispose();
  }

  List<Product> get _visibleProducts {
    final query = productSearchController.text.trim().toLowerCase();
    return widget.products.where((item) {
      if (item.stock <= 0) return false;
      return query.isEmpty ||
          item.name.toLowerCase().contains(query) ||
          item.barcode.toLowerCase().contains(query);
    }).toList();
  }

  int get cartTotal => cart.fold(0, (sum, line) => sum + line.total);

  int _quantityInCart(Product item) => cart
      .where((line) => identical(line.product, item))
      .fold(0, (sum, line) => sum + line.quantity);

  void _addProduct(Product product) {
    if (product.stock - _quantityInCart(product) <= 0) return;
    setState(() {
      final index = cart.indexWhere((line) => identical(line.product, product));
      if (index >= 0) {
        cart[index].quantity++;
      } else {
        cart.add(SaleLine(product, 1));
      }
    });
    barcodeFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    final desktop = windowWidth >= 1250;
    final catalog = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: barcodeController,
          focusNode: barcodeFocus,
          autofocus: true,
          onChanged: _barcodeChanged,
          onSubmitted: _submitBarcode,
          decoration: const InputDecoration(
            labelText: 'Lecteur de code-barres USB',
            hintText: 'Scannez : le produit s’ajoute automatiquement',
            prefixIcon: Icon(Icons.qr_code_scanner),
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: true,
          child: Text(
            scanMessage,
            style: TextStyle(
              color: scanError ? const Color(0xFFB3261E) : _green,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: productSearchController,
          onChanged: (_) => setState(() {}),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              _submitBarcode(value);
              productSearchController.clear();
              setState(() {});
            }
          },
          decoration: InputDecoration(
            labelText: 'Rechercher un produit',
            hintText: 'Nom ou code-barres',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: productSearchController.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      productSearchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(child: _productGrid()),
      ],
    );
    return PopScope(
      canPop: !validating,
      child: AbsorbPointer(
        absorbing: validating,
        child: Focus(
          child: Container(
            height: double.infinity,
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            decoration: const BoxDecoration(color: _cream),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Fermer la vente',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Nouvelle vente',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          color: _dark,
                        ),
                      ),
                    ),
                    Badge(
                      label: Text('${cart.length}'),
                      child: const Icon(
                        Icons.shopping_cart_outlined,
                        color: _green,
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filledTonal(
                      tooltip: 'Scanner pour ajouter',
                      onPressed: _scanIntoCart,
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Configurer l’impression du ticket',
                      onPressed: _configurePrinting,
                      icon: Icon(
                        printSettings.enabled
                            ? Icons.print
                            : Icons.print_disabled_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: desktop
                      ? Row(
                          children: [
                            Expanded(flex: 7, child: catalog),
                            const SizedBox(width: 18),
                            SizedBox(width: 410, child: _cartPanel()),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(flex: 6, child: catalog),
                            const SizedBox(height: 12),
                            Expanded(flex: 5, child: _cartPanel()),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _productGrid() {
    final products = _visibleProducts;
    if (products.isEmpty)
      return const Center(child: Text('Aucun produit disponible'));
    return ListView.separated(
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemCount: products.length,
      itemBuilder: (_, index) {
        final item = products[index];
        final remaining = item.stock - _quantityInCart(item);
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: remaining > 0 ? () => _addProduct(item) : null,
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _green.withValues(alpha: .14)),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 480
                    ? Row(
                        children: [
                          SizedBox(
                            width: 140,
                            height: 150,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(15),
                              ),
                              child: _productImage(item),
                            ),
                          ),
                          Expanded(
                            child: _productDetails(
                              item,
                              remaining,
                              large: true,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: 105,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(15),
                              ),
                              child: _productImage(item),
                            ),
                          ),
                          _productDetails(item, remaining),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _productDetails(Product item, int remaining, {bool large = false}) =>
      Padding(
        padding: EdgeInsets.all(large ? 18 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              item.name,
              style: TextStyle(
                fontSize: large ? 21 : 17,
                color: _dark,
                fontWeight: FontWeight.w900,
                height: 1.15,
              ),
            ),
            SizedBox(height: large ? 8 : 6),
            Text(
              '${money(item.price)} FCFA',
              style: TextStyle(
                fontSize: large ? 19 : 16,
                fontWeight: FontWeight.w900,
                color: _green,
              ),
            ),
            SizedBox(height: large ? 5 : 4),
            Text(
              '$remaining disponible${remaining > 1 ? 's' : ''}',
              style: TextStyle(
                fontSize: large ? 13 : 12,
                color: const Color(0xFF46534D),
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: large ? 8 : 7),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: remaining > 0 ? () => _addProduct(item) : null,
                icon: Icon(Icons.add, size: large ? 20 : 18),
                label: Text(
                  'Ajouter au panier',
                  style: TextStyle(
                    fontSize: large ? 14 : 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: Size(0, large ? 42 : 38),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _productImage(Product item) {
    if (item.imagePath.isNotEmpty && File(item.imagePath).existsSync())
      return ColoredBox(
        color: const Color(0xFFF6F7F4),
        child: Image.file(File(item.imagePath), fit: BoxFit.contain),
      );
    if (item.imageUrl.isNotEmpty)
      return Image.network(
        item.imageUrl,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _fallbackProductImage(item),
      );
    return _fallbackProductImage(item);
  }

  Widget _fallbackProductImage(Product item) => ColoredBox(
    color: _green.withValues(alpha: .08),
    child: Icon(item.icon, size: 54, color: _green),
  );

  Widget _cartPanel() => Card(
    margin: EdgeInsets.zero,
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: SizedBox(
          height: constraints.maxHeight.clamp(
            480 * MediaQuery.textScalerOf(context).scale(1),
            double.infinity,
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Panier (${cart.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: cart.isEmpty
                      ? const Center(
                          child: Text(
                            'Sélectionnez des produits',
                            style: TextStyle(color: Colors.black45),
                          ),
                        )
                      : ListView.separated(
                          itemCount: cart.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (_, index) {
                            final line = cart[index];
                            return Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        line.product.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      Text(
                                        '${money(line.product.price)} F × ${line.quantity}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: line.quantity > 1
                                      ? () => setState(() => line.quantity--)
                                      : null,
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                                Text(
                                  '${line.quantity}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                IconButton(
                                  onPressed: line.quantity < line.product.stock
                                      ? () => setState(() => line.quantity++)
                                      : null,
                                  icon: const Icon(
                                    Icons.add_circle_outline,
                                    color: _green,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      setState(() => cart.removeAt(index)),
                                  icon: const Icon(
                                    Icons.close,
                                    color: Color(0xFFD56A4D),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: clientController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Client (facultatif)',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: ['Espèces', 'Orange Money', 'Moov Money', 'Crédit']
                      .map(
                        (item) => ChoiceChip(
                          label: Text(item),
                          selected: payment == item,
                          onSelected: (_) => setState(() => payment = item),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      'Total',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${money(cartTotal)} FCFA',
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                        color: _green,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _configurePrinting,
                  icon: Icon(
                    printSettings.enabled
                        ? Icons.print
                        : Icons.print_disabled_outlined,
                  ),
                  label: Text(
                    printSettings.enabled
                        ? 'Ticket automatique : ${printSettings.printer?.name ?? "imprimante à choisir"}'
                        : 'Activer l’impression du ticket',
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: cart.isEmpty || validating
                        ? null
                        : _validateSale,
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(
                      validating
                          ? 'Validation en cours…'
                          : printSettings.enabled
                          ? 'Valider et imprimer'
                          : 'Valider la vente',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _validateSale() async {
    if (validating || cart.isEmpty) return;
    barcodeTimer?.cancel();
    hardwareBarcodeTimer?.cancel();
    setState(() => validating = true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await widget.onValidated(
        cart.map((line) => SaleLine(line.product, line.quantity)).toList(),
        payment,
        clientController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        cart.clear();
        payment = 'Espèces';
        clientController.clear();
        productSearchController.clear();
        barcodeController.clear();
        keyboardBarcode = '';
        lastBarcodeKey = null;
        scanError = false;
        scanMessage =
            'Nouvelle vente prête. Scannez ou sélectionnez un produit.';
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vente non enregistrée. Le panier est conservé ; réessayez.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => validating = false);
        barcodeFocus.requestFocus();
      }
    }
  }

  Future<void> _scanIntoCart() async {
    final codes = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => const ContinuousBarcodeScannerPage()),
    );
    if (codes == null || codes.isEmpty || !mounted) return;
    var added = 0;
    var unknown = 0;
    setState(() {
      for (final code in codes) {
        Product? found;
        for (final item in widget.products) {
          if (item.barcode == code) {
            found = item;
            break;
          }
        }
        if (found == null) {
          unknown++;
          continue;
        }
        final existing = cart.indexWhere(
          (line) => identical(line.product, found),
        );
        final already = existing >= 0 ? cart[existing].quantity : 0;
        if (already >= found.stock) continue;
        if (existing >= 0) {
          cart[existing].quantity++;
        } else {
          cart.add(SaleLine(found, 1));
        }
        added++;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$added produit(s) ajouté(s)${unknown > 0 ? ' • $unknown code(s) inconnu(s)' : ''}',
        ),
      ),
    );
  }
}

String money(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return out.toString();
}
