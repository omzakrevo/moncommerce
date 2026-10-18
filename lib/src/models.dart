part of '../main.dart';

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
