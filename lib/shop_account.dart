import 'package:supabase_flutter/supabase_flutter.dart';

/// One shop per authenticated account. The profile primary key is the user id.
class ShopAccountService {
  ShopAccountService(this.client);
  final SupabaseClient client;

  Future<String?> shopName(String userId) async {
    final profile = await client
        .from('profiles')
        .select('shop_name')
        .eq('id', userId)
        .maybeSingle();
    final name = profile?['shop_name']?.toString().trim();
    return name == null || name.isEmpty ? null : name;
  }

  Future<String> configure(String userId, String name) async {
    final existing = await shopName(userId);
    if (existing != null) {
      return existing;
    }
    if (name.trim().isEmpty) {
      throw StateError('Indiquez le nom de votre boutique.');
    }
    // A concurrent first login must not rename a profile created on another device.
    await client
        .from('profiles')
        .upsert(
          {'id': userId, 'shop_name': name.trim()},
          onConflict: 'id',
          ignoreDuplicates: true,
        );
    final saved = await shopName(userId);
    if (saved == null) {
      // Some older accounts already have an empty profile created by a trigger.
      await client
          .from('profiles')
          .update({'shop_name': name.trim()})
          .eq('id', userId)
          .or('shop_name.is.null,shop_name.eq.');
    }
    return await shopName(userId) ??
        (throw StateError('Configuration de la boutique impossible.'));
  }
}
