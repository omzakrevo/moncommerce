import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

const localStaffLoginRequiredKey = 'local_staff_login_required_v1';
const localStaffRoles = [
  'Caissier',
  'Caissière',
  'Vendeur',
  'Gestionnaire',
  'Administrateur',
];

class LocalStaffAccount {
  const LocalStaffAccount({
    required this.id,
    required this.shopId,
    required this.shopName,
    required this.name,
    required this.login,
    required this.role,
    required this.active,
    this.salt = '',
    this.passwordHash = '',
  });
  final String id, shopId, shopName, name, login, role, salt, passwordHash;
  final bool active;
  bool get configured => salt.isNotEmpty && passwordHash.isNotEmpty;
  bool get canManageStock => role == 'Gestionnaire' || role == 'Administrateur';
  bool get canManageUsers => role == 'Administrateur';
  Map<String, dynamic> toJson() => {
    'id': id,
    'shopId': shopId,
    'shopName': shopName,
    'name': name,
    'login': login,
    'role': role,
    'active': active,
    'salt': salt,
    'passwordHash': passwordHash,
    'passwordScheme': 'pbkdf2-sha256-600000',
  };
  factory LocalStaffAccount.fromJson(Map<String, dynamic> json) =>
      LocalStaffAccount(
        id: json['id'] as String,
        shopId: json['shopId'] as String,
        shopName: json['shopName'] as String,
        name: json['name'] as String,
        login: json['login'] as String,
        role: json['role'] as String,
        active: json['active'] == true,
        salt: json['salt'] as String? ?? '',
        passwordHash: json['passwordHash'] as String? ?? '',
      );
}

class LocalStaffStore {
  static const storageKey = 'local_staff_accounts_v1';

  Future<List<LocalStaffAccount>> _all() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map(
          (j) =>
              LocalStaffAccount.fromJson(Map<String, dynamic>.from(j as Map)),
        )
        .toList();
  }

  Future<List<LocalStaffAccount>> forShop(String shopId) async =>
      (await _all()).where((a) => a.shopId == shopId).toList();

  Future<void> _write(List<LocalStaffAccount> accounts) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      storageKey,
      jsonEncode(accounts.map((a) => a.toJson()).toList()),
    )) {
      throw StateError('Impossible d’enregistrer les comptes locaux.');
    }
  }

  String _random() =>
      base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256)));

  static Future<String> _hash(
    String password,
    String salt,
  ) => Isolate.run(() async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 600000,
      bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: base64Url.decode(salt));
    return base64UrlEncode(await key.extractBytes());
  });

  Future<LocalStaffAccount> save({
    String? id,
    required String shopId,
    required String shopName,
    required String name,
    required String login,
    required String role,
    required bool active,
    String password = '',
    String? actingAccountId,
  }) async {
    final normalized = login.trim().toLowerCase();
    if (name.trim().isEmpty ||
        !RegExp(r'^[a-z0-9._@+\-]{3,80}$').hasMatch(normalized)) {
      throw StateError(
        'Indiquez un nom et un identifiant de 3 à 80 caractères (lettres, chiffres, . _ @ + -).',
      );
    }
    if (!localStaffRoles.contains(role) || shopId.isEmpty)
      throw StateError('Rôle ou boutique invalide.');
    final accounts = await _all();
    final existing = accounts.where((a) => a.id == id).firstOrNull;
    if (id != null && (existing == null || existing.shopId != shopId)) {
      throw StateError('Compte introuvable dans cette boutique.');
    }
    if (accounts.any((a) => a.id != id && a.login == normalized)) {
      throw StateError('Cet identifiant est déjà utilisé sur cet appareil.');
    }
    if (id != null &&
        id == actingAccountId &&
        (!active || role != 'Administrateur')) {
      throw StateError(
        'Vous ne pouvez pas retirer votre propre accès administrateur.',
      );
    }
    if ((existing?.configured != true || password.isNotEmpty) &&
        password.length < 6) {
      throw StateError('Choisissez un mot de passe d’au moins 6 caractères.');
    }
    final salt = password.isEmpty ? existing!.salt : _random();
    final digest = password.isEmpty
        ? existing!.passwordHash
        : await _hash(password, salt);
    final account = LocalStaffAccount(
      id: id ?? _random(),
      shopId: shopId,
      shopName: shopName,
      name: name.trim(),
      login: normalized,
      role: role,
      active: active,
      salt: salt,
      passwordHash: digest,
    );
    // Re-read after hashing so a simultaneous unrelated edit is not lost.
    final latest = await _all();
    if (latest.any((a) => a.id != id && a.login == normalized))
      throw StateError('Identifiant déjà utilisé.');
    latest.removeWhere((a) => a.id == id);
    latest.add(account);
    await _write(latest);
    return account;
  }

  Future<void> delete(
    String shopId,
    String id, {
    String? actingAccountId,
  }) async {
    if (id == actingAccountId)
      throw StateError('Vous ne pouvez pas supprimer votre propre compte.');
    final accounts = await _all();
    accounts.removeWhere((a) => a.shopId == shopId && a.id == id);
    await _write(accounts);
  }

  Future<LocalStaffAccount> authenticate(String login, String password) async {
    final normalized = login.trim().toLowerCase();
    final prefs = await SharedPreferences.getInstance();
    final attemptKey =
        'local_staff_attempt_${base64UrlEncode(utf8.encode(normalized))}';
    final attempts = jsonDecode(prefs.getString(attemptKey) ?? '{}') as Map;
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((attempts['until'] as int? ?? 0) > now) {
      throw StateError('Trop de tentatives. Réessayez dans 30 secondes.');
    }
    final account = (await _all())
        .where((a) => a.login == normalized)
        .firstOrNull;
    var valid = false;
    if (account != null &&
        account.active &&
        account.configured &&
        localStaffRoles.contains(account.role)) {
      final actual = await _hash(password, account.salt);
      var difference = actual.length ^ account.passwordHash.length;
      for (
        var i = 0;
        i < min(actual.length, account.passwordHash.length);
        i++
      ) {
        difference |= actual.codeUnitAt(i) ^ account.passwordHash.codeUnitAt(i);
      }
      valid = difference == 0;
    }
    if (!valid) {
      final count = (attempts['count'] as int? ?? 0) + 1;
      await prefs.setString(
        attemptKey,
        jsonEncode({
          'count': count >= 5 ? 0 : count,
          'until': count >= 5 ? now + 30000 : 0,
        }),
      );
      throw StateError(
        'Identifiant ou mot de passe incorrect, ou compte désactivé.',
      );
    }
    await prefs.remove(attemptKey);
    return account!;
  }

  /// Old directory entries never grant access until an administrator assigns credentials.
  Future<void> importLegacy(String shopId, String shopName) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('local_staff_legacy_imported_v1') == true) return;
    final legacy = jsonDecode(prefs.getString('users_v1') ?? '[]') as List;
    final accounts = await _all();
    for (final raw in legacy) {
      final item = Map<String, dynamic>.from(raw as Map);
      accounts.add(
        LocalStaffAccount(
          id: _random(),
          shopId: shopId,
          shopName: shopName,
          name: item['name']?.toString() ?? 'Utilisateur',
          login: '',
          role: localStaffRoles.contains(item['detail'])
              ? item['detail'] as String
              : 'Caissier',
          active: false,
        ),
      );
    }
    await _write(accounts);
    await prefs.setBool('local_staff_legacy_imported_v1', true);
  }
}
