import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ShopSyncConflict implements Exception {
  const ShopSyncConflict();
}

class ShopSnapshot {
  const ShopSnapshot(this.revision, this.data);
  final int revision;
  final Map<String, dynamic> data;
}

abstract class ShopSyncRemote {
  Future<ShopSnapshot?> read();
  Future<int> write(Map<String, dynamic> data, int expectedRevision);
}

class SupabaseShopSyncRemote implements ShopSyncRemote {
  SupabaseShopSyncRemote(this.client, this.userId);
  final SupabaseClient client;
  final String userId;
  @override
  Future<ShopSnapshot?> read() async {
    final row = await client
        .from('shop_snapshots')
        .select('revision,payload')
        .eq('owner_id', userId)
        .maybeSingle();
    return row == null
        ? null
        : ShopSnapshot(
            (row['revision'] as num).toInt(),
            Map<String, dynamic>.from(row['payload'] as Map),
          );
  }

  @override
  Future<int> write(Map<String, dynamic> data, int expectedRevision) async {
    try {
      final result = await client.rpc(
        'save_shop_snapshot',
        params: {'p_expected_revision': expectedRevision, 'p_payload': data},
      );
      return (result as num).toInt();
    } on PostgrestException catch (error) {
      if (error.code == '40001') {
        throw const ShopSyncConflict();
      }
      rethrow;
    }
  }
}

String canonicalShopData(Object? data) {
  Object? order(Object? value) {
    if (value is Map) {
      return {
        for (final key in value.keys.map((k) => k.toString()).toList()..sort())
          key: order(value[key]),
      };
    }
    if (value is List) {
      return value.map(order).toList();
    }
    return value;
  }

  return jsonEncode(order(data));
}

/// Optimistic revisions prevent a stale device from replacing a newer shop.
class ShopSync {
  ShopSync(this.userId, this.remote, this.preferences);
  final String userId;
  final ShopSyncRemote remote;
  final SharedPreferences preferences;
  String get baselineKey => 'shop_sync_baseline_$userId';
  String get revisionKey => 'shop_sync_revision_$userId';
  int? synchronizedRevision;

  Future<Map<String, dynamic>> synchronize(
    Map<String, dynamic> local, {
    required bool hasLocalData,
    bool remember = true,
  }) async {
    final encoded = canonicalShopData(local);
    final base = preferences.getString(baselineKey);
    final revision = preferences.getInt(revisionKey) ?? 0;
    final remoteState = await remote.read();
    final meaningful = local.values.any(
      (value) => value is List
          ? value.isNotEmpty
          : value is Map
          ? value.isNotEmpty
          : value is num
          ? value != 0
          : value is String
          ? value.isNotEmpty
          : value == true,
    );
    final dirty =
        hasLocalData && encoded != base && (base != null || meaningful);
    // A newly installed, empty device must never claim the first cloud revision.
    if (remoteState == null && base == null && !meaningful) {
      return local;
    }
    if (remoteState != null) {
      final remoteEncoded = canonicalShopData(remoteState.data);
      if (dirty &&
          revision != remoteState.revision &&
          encoded != remoteEncoded) {
        // Keep both versions. The user can inspect exported local data before resolving.
        await preferences.setString(
          'shop_sync_remote_backup_$userId',
          jsonEncode(remoteState.data),
        );
        throw const ShopSyncConflict();
      }
      if (!dirty || encoded == remoteEncoded) {
        synchronizedRevision = remoteState.revision;
        if (remember) await _remember(remoteState.data, remoteState.revision);
        return remoteState.data;
      }
    }
    final next = await remote.write(local, remoteState?.revision ?? 0);
    synchronizedRevision = next;
    if (remember) await _remember(local, next);
    return local;
  }

  Future<void> commit(Map<String, dynamic> appliedData) async {
    if (synchronizedRevision != null)
      await _remember(appliedData, synchronizedRevision!);
  }

  Future<void> _remember(Map<String, dynamic> data, int revision) async {
    if (!await preferences.setString(baselineKey, canonicalShopData(data)) ||
        !await preferences.setInt(revisionKey, revision)) {
      throw StateError('Impossible de mémoriser la synchronisation.');
    }
  }
}
