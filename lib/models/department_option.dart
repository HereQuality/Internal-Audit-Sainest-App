/// A pickable Department for the "where" filter — GET /locations/my-scope's
/// `departments` list (a department is just another kind of place to the
/// people filtering by it, see the web's LocationFilterSelect).
class DepartmentOption {
  final String id;
  final String name;
  final String? code;

  const DepartmentOption({required this.id, required this.name, this.code});

  String get display => (code != null && code!.isNotEmpty) ? '$name ($code)' : name;

  factory DepartmentOption.fromJson(Map<String, dynamic> json) {
    return DepartmentOption(
      id: (json['_id'] ?? '').toString(),
      name: json['departmentName']?.toString() ?? 'Department',
      code: json['departmentCode']?.toString(),
    );
  }
}
