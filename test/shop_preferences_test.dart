import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moncommerce/shop_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'les paramètres et documents restent séparés entre propriétaires',
    () async {
      SharedPreferences.setMockInitialValues({
        'shop_phone': '111',
        'commercial_documents_v1': '[{"id":"facture-a"}]',
      });
      final prefs = await SharedPreferences.getInstance();
      await activateShopPreferences(prefs, 'a', legacyOwner: 'a');
      expect(prefs.getString('shop_phone'), '111');
      await activateShopPreferences(prefs, 'b', legacyOwner: 'a');
      expect(prefs.getString('shop_phone'), isNull);
      expect(prefs.getString('commercial_documents_v1'), isNull);
      await prefs.setString('shop_phone', '222');
      await activateShopPreferences(prefs, 'a');
      expect(prefs.getString('shop_phone'), '111');
      expect(prefs.getString('commercial_documents_v1'), contains('facture-a'));
      await activateShopPreferences(prefs, 'b');
      expect(prefs.getString('shop_phone'), '222');
    },
  );
}
