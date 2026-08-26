class UserPreferences {
  final String themeMode;
  final bool showDashboardClock;
  // Mirrors the web dashboard's own Settings > Notifications > Email
  // Notifications switch — same server-side preferences.emailNotifications
  // field (server/models/Employee.js / user.model.js), toggleable from
  // either platform. Distinct from the phone's own local push-notification
  // toggle (see SettingsScreen's "Notifications" switch, backed by
  // NotificationPrefs — phone-only, no server field, since only the phone
  // actually fires local notifications).
  final bool emailNotifications;
  // Per-type breakdown of the above — same server-side preferences.
  // emailNotificationTypes field the web dashboard's Settings page reads/
  // writes (server/models/Employee.js). Keys match the `type` argument
  // createNotification/notifyAssignees is called with (audit.controller.js
  // / nc.controller.js / scheduledNotifications.js). A key missing here
  // (never explicitly turned off) reads as on — see the `!= false` checks
  // wherever this is consulted, same convention notification.service.js's
  // own server-side gate uses.
  final Map<String, bool> emailNotificationTypes;

  const UserPreferences({
    this.themeMode = 'light',
    this.showDashboardClock = true,
    this.emailNotifications = true,
    this.emailNotificationTypes = const {},
  });

  factory UserPreferences.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const UserPreferences();
    final rawTypes = json['emailNotificationTypes'];
    return UserPreferences(
      themeMode: json['themeMode']?.toString() ?? 'light',
      showDashboardClock: json['showDashboardClock'] as bool? ?? true,
      emailNotifications: json['emailNotifications'] as bool? ?? true,
      emailNotificationTypes: rawTypes is Map
          ? rawTypes.map((k, v) => MapEntry(k.toString(), v as bool? ?? true))
          : const {},
    );
  }

  UserPreferences copyWith({
    String? themeMode,
    bool? showDashboardClock,
    bool? emailNotifications,
    Map<String, bool>? emailNotificationTypes,
  }) {
    return UserPreferences(
      themeMode: themeMode ?? this.themeMode,
      showDashboardClock: showDashboardClock ?? this.showDashboardClock,
      emailNotifications: emailNotifications ?? this.emailNotifications,
      emailNotificationTypes:
          emailNotificationTypes ?? this.emailNotificationTypes,
    );
  }
}

/// Name lookups from populated departmentIds / locationIds on login.
class NamedRef {
  final String id;
  final String name;

  const NamedRef({required this.id, required this.name});

  factory NamedRef.fromJson(
    Map<String, dynamic> json, {
    String nameField = 'name',
  }) {
    return NamedRef(
      id: (json['_id'] ?? '').toString(),
      name: (json[nameField] ?? json['name'] ?? '').toString(),
    );
  }
}

class UserModel {
  final String id;
  final String roleType; // "SuperAdmin" | "Employee"
  final String name;
  final String username;
  final String email;
  final String mobileNumber;
  final String? profilePic;
  final String? roleName;
  final List<NamedRef> departments;
  final List<NamedRef> locations;
  final List<String> skills;
  final String? joiningDate;
  final String? address;
  final String? city;
  final String? state;
  final String? country;
  final String? remark;
  final UserPreferences preferences;

  const UserModel({
    required this.id,
    required this.roleType,
    required this.name,
    required this.username,
    required this.email,
    required this.mobileNumber,
    this.profilePic,
    this.roleName,
    this.departments = const [],
    this.locations = const [],
    this.skills = const [],
    this.joiningDate,
    this.address,
    this.city,
    this.state,
    this.country,
    this.remark,
    this.preferences = const UserPreferences(),
  });

  bool get isEmployee => roleType == 'Employee';

  factory UserModel.fromJson(Map<String, dynamic> json) {
    List<NamedRef> parseRefs(dynamic value, String nameField) {
      if (value is! List) return const [];
      return value
          .whereType<Map>()
          .map(
            (e) => NamedRef.fromJson(
              Map<String, dynamic>.from(e),
              nameField: nameField,
            ),
          )
          .toList();
    }

    return UserModel(
      id: (json['_id'] ?? json['id'] ?? '').toString(),
      roleType: json['roleType']?.toString() ?? 'Employee',
      name: (json['employeeName'] ?? json['name'] ?? '').toString(),
      username: json['username']?.toString() ?? '',
      email: (json['emailOffice'] ?? json['email'] ?? '').toString(),
      mobileNumber: json['mobileNumber']?.toString() ?? '',
      profilePic: json['profilePic']?.toString(),
      roleName: json['roleName']?.toString(),
      departments: parseRefs(json['departmentIds'], 'departmentName'),
      locations: parseRefs(json['locationIds'], 'name'),
      skills:
          (json['skills'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      joiningDate: json['joiningDate']?.toString(),
      address: json['address']?.toString(),
      city: json['city']?.toString(),
      state: json['state']?.toString(),
      country: json['country']?.toString(),
      remark: json['remark']?.toString(),
      preferences: UserPreferences.fromJson(
        json['preferences'] as Map<String, dynamic>?,
      ),
    );
  }

  UserModel copyWith({
    String? name,
    String? username,
    String? email,
    String? mobileNumber,
    String? profilePic,
    String? address,
    String? city,
    String? state,
    String? country,
    UserPreferences? preferences,
  }) {
    return UserModel(
      id: id,
      roleType: roleType,
      name: name ?? this.name,
      username: username ?? this.username,
      email: email ?? this.email,
      mobileNumber: mobileNumber ?? this.mobileNumber,
      profilePic: profilePic ?? this.profilePic,
      roleName: roleName,
      departments: departments,
      locations: locations,
      skills: skills,
      joiningDate: joiningDate,
      address: address ?? this.address,
      city: city ?? this.city,
      state: state ?? this.state,
      country: country ?? this.country,
      remark: remark,
      preferences: preferences ?? this.preferences,
    );
  }
}
