import 'package:flutter/material.dart';
import 'local_staff.dart';

class LocalStaffPage extends StatefulWidget {
  const LocalStaffPage({
    super.key,
    required this.shopId,
    required this.shopName,
    this.actingAccountId,
  });
  final String shopId, shopName;
  final String? actingAccountId;
  @override
  State<LocalStaffPage> createState() => _LocalStaffPageState();
}

class _LocalStaffPageState extends State<LocalStaffPage> {
  final store = LocalStaffStore();
  List<LocalStaffAccount> accounts = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await store.importLegacy(widget.shopId, widget.shopName);
      final rows = await store.forShop(widget.shopId);
      if (mounted)
        setState(() {
          accounts = rows;
          error = null;
        });
    } catch (_) {
      if (mounted)
        setState(() => error = 'Impossible de charger les utilisateurs.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _edit([LocalStaffAccount? account]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _StaffEditor(
        shopId: widget.shopId,
        shopName: widget.shopName,
        account: account,
        actingAccountId: widget.actingAccountId,
      ),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _delete(LocalStaffAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Supprimer ${account.name} ?'),
        content: const Text(
          'Cet utilisateur ne pourra plus se connecter. Ses ventes restent enregistrées.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await store.delete(
        widget.shopId,
        account.id,
        actingAccountId: widget.actingAccountId,
      );
      await _load();
    } catch (failure) {
      if (mounted)
        setState(
          () => error = failure is StateError
              ? failure.message.toString()
              : 'Suppression impossible.',
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Utilisateurs • accès hors ligne')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: loading ? null : () => _edit(),
      icon: const Icon(Icons.person_add),
      label: const Text('Créer un utilisateur'),
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 90),
            children: [
              const Text(
                'Créez un identifiant et un mot de passe pour chaque utilisateur. Il pourra se connecter sans Internet sur cet appareil et retrouver les produits et ventes de cette boutique.',
              ),
              const SizedBox(height: 12),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (accounts.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Aucun utilisateur enregistré.'),
                ),
              for (final account in accounts)
                Card(
                  child: ListTile(
                    onTap: () => _edit(account),
                    leading: const Icon(Icons.badge_outlined),
                    title: Text(account.name),
                    subtitle: Text(
                      '${account.login.isEmpty ? "Identifiant à définir" : account.login} • ${account.role}\n${!account.configured
                          ? "Connexion à configurer"
                          : account.active
                          ? "Actif"
                          : "Désactivé"}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) => action == 'delete'
                          ? _delete(account)
                          : _edit(account),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('Modifier / mot de passe'),
                        ),
                        if (account.id != widget.actingAccountId)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Supprimer'),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}

class _StaffEditor extends StatefulWidget {
  const _StaffEditor({
    required this.shopId,
    required this.shopName,
    this.account,
    this.actingAccountId,
  });
  final String shopId, shopName;
  final LocalStaffAccount? account;
  final String? actingAccountId;
  @override
  State<_StaffEditor> createState() => _StaffEditorState();
}

class _StaffEditorState extends State<_StaffEditor> {
  late final name = TextEditingController(text: widget.account?.name);
  late final login = TextEditingController(text: widget.account?.login);
  final password = TextEditingController();
  late String role = widget.account?.role ?? 'Caissier';
  late bool active = widget.account?.configured == true
      ? widget.account!.active
      : true;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    login.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await LocalStaffStore().save(
        id: widget.account?.id,
        shopId: widget.shopId,
        shopName: widget.shopName,
        name: name.text,
        login: login.text,
        role: role,
        active: active,
        password: password.text,
        actingAccountId: widget.actingAccountId,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted)
        setState(() {
          busy = false;
          error = failure is StateError
              ? failure.message.toString()
              : 'Enregistrement impossible.';
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(
        widget.account == null
            ? 'Nouvel utilisateur'
            : 'Modifier l’utilisateur',
      ),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Nom de l’utilisateur',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: login,
                enabled: !busy,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Identifiant de connexion',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                enabled: !busy,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Mot de passe local',
                  helperText: widget.account?.configured == true
                      ? 'Laisser vide pour conserver le mot de passe.'
                      : 'Au moins 6 caractères.',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: role,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Rôle'),
                items: localStaffRoles
                    .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                    .toList(),
                onChanged: busy ? null : (r) => setState(() => role = r!),
              ),
              const SizedBox(height: 8),
              const Text(
                'Caissier / Caissière / Vendeur : ventes. Gestionnaire : ventes, stock et rapports. Administrateur : ces accès et gestion des utilisateurs locaux.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Compte actif'),
                value: active,
                onChanged: busy ? null : (v) => setState(() => active = v),
              ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: busy ? null : _save,
          child: Text(busy ? 'Enregistrement…' : 'Enregistrer'),
        ),
      ],
    ),
  );
}
