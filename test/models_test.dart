import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/main.dart';

void main() {
  test('un produit conserve ses données après sérialisation', () {
    final product = Product(
      'Farine',
      750,
      15,
      Icons.inventory_2_outlined,
      purchasePrice: 500,
    );
    final restored = Product.fromJson(product.toJson());

    expect(restored.name, 'Farine');
    expect(restored.price, 750);
    expect(restored.stock, 15);
    expect(restored.purchasePrice, 500);
  });

  test('les anciens produits sans prix d’achat restent lisibles', () {
    final product = Product.fromJson({
      'name': 'Riz',
      'price': 1000,
      'stock': 3,
    });
    expect(product.purchasePrice, isNull);
    expect(product.price, 1000);
    product.purchasePrice = 0;
    expect(Product.fromJson(product.toJson()).purchasePrice, 0);
  });

  test('un crédit conserve ses données après sérialisation', () {
    final credit = Credit('Issa', '70 00 00 00', 5000, '10 août');
    final restored = Credit.fromJson(credit.toJson());

    expect(restored.customer, 'Issa');
    expect(restored.amount, 5000);
  });

  test('une vente conserve ses données après sérialisation', () {
    final sale = SaleRecord('Riz', 14500, 'Espèces', '12:30');
    final restored = SaleRecord.fromJson(sale.toJson());

    expect(restored.product, 'Riz');
    expect(restored.payment, 'Espèces');
    expect(restored.amount, 14500);
  });

  test('un client commercial conserve ses coordonnées', () {
    final customer = CommercialCustomer(
      name: 'Société Faso Distribution',
      phone: '70 00 00 00',
      address: 'Ouagadougou',
      isCompany: true,
    );
    final restored = CommercialCustomer.fromJson(customer.toJson());

    expect(restored.name, 'Société Faso Distribution');
    expect(restored.phone, '70 00 00 00');
    expect(restored.isCompany, isTrue);
  });
}
