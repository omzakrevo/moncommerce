part of '../main.dart';

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
