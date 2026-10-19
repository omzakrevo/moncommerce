part of '../main.dart';

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
  Widget build(BuildContext context) {
    final form = Column(
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
              ButtonSegment(value: true, label: Text('Utilisateur hors ligne')),
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
            labelText: _local ? 'Identifiant de connexion' : 'Adresse email',
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
    );
    final card = Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F0F1F46),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: form,
    );
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      backgroundColor: _cream,
      body: SafeArea(
        child: wide
            ? Row(
                children: [
                  Expanded(child: _brandPanel()),
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(32),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 460),
                          child: card,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 430),
                    child: card,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _brandPanel() => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [_dark, _green],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    padding: const EdgeInsets.all(56),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.storefront_rounded, color: _green, size: 36),
        ),
        const SizedBox(height: 28),
        const Text(
          'Bienvenue sur MonCommerce',
          style: TextStyle(
            color: Colors.white,
            fontSize: 36,
            fontWeight: FontWeight.w900,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Gérez. Suivez. Développez.',
          style: TextStyle(color: Colors.white70, fontSize: 18),
        ),
        const SizedBox(height: 36),
        for (final line in const [
          'Caisse rapide avec scanner de codes-barres',
          'Stock, crédits, dépenses et rapports',
          'Boutique synchronisée entre vos appareils',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: Colors.white,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    line,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}
