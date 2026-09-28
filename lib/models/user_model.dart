class UserPreferences {
  final String themeMode;
  final bool showDashboardClock;
  // The two account-level notification switches — the SAME server-side
  // preferences.emailNotifications / preferences.pushNotifications fields
  // (server/models/Employee.js / user.model.js) the web dashboard's
  // Settings > Notifications card reads and writes, so flipping either one
  // on either platform changes it for both. "Push" covers this phone AND
  // the browser, every notification type including support tickets. A
  // missing value reads as on, same default the server applies.
  final bool emailNotifications;
  final bool pushNotifications;
  // The per-topic switches under those two masters, keyed by notification
  // type ('audit_created', 'nc_rejected', ...; the full list is
  // kNotificationTopics). A key only counts while its master is on. The
  // server sends every key with its EFFECTIVE value; a key that is missing
  // (an older server, a partial socket payload) reads as on — see
  // [emailTypeOn] / [pushTypeOn] — so a payload never has to be complete.
  final Map<String, bool> emailNotificationTypes;
  final Map<String, bool> pushNotificationTypes;

  const UserPreferences({
    this.themeMode = 'light',
    this.showDashboardClock = true,
    this.emailNotifications = true,
    this.pushNotifications = true,
    this.emailNotificationTypes = const {},
    this.pushNotificationTypes = const {},
  });

  bool emailTypeOn(String type) => emailNotificationTypes[type] ?? true;
  bool pushTypeOn(String type) => pushNotificationTypes[type] ?? true;

  /// Reads a `{type: bool}` map off any decoded JSON value. Anything that is
  /// not a boolean is dropped rather than guessed at, so a malformed entry
  /// reads as the default (on) instead of throwing mid-parse.
  static Map<String, bool> parseTypeMap(dynamic raw) {
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.value is bool) entry.key.toString(): entry.value as bool,
    };
  }

  factory UserPreferences.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const UserPreferences();
    return UserPreferences(
      themeMode: json['themeMode']?.toString() ?? 'light',
      showDashboardClock: json['showDashboardClock'] as bool? ?? true,
      emailNotifications: json['emailNotifications'] as bool? ?? true,
      pushNotifications: json['pushNotifications'] as bool? ?? true,
      emailNotificationTypes: parseTypeMap(json['emailNotificationTypes']),
      pushNotificationTypes: parseTypeMap(json['pushNotificationTypes']),
    );
  }

  /// This object with a 'preferences_updated' socket event's payload merged
  /// in. Whatever the event carries replaces what is held (the two per-topic
  /// maps key by key, so a partial map never drops the topics it omits); what
  /// it leaves out — an older server sends only the two masters — keeps its
  /// value.
  UserPreferences mergedWithEvent(Map data) {
    final email = data['emailNotifications'];
    final push = data['pushNotifications'];
    final emailTypes = data['emailNotificationTypes'];
    final pushTypes = data['pushNotificationTypes'];
    return copyWith(
      emailNotifications: email is bool ? email : null,
      pushNotifications: push is bool ? push : null,
      emailNotificationTypes: emailTypes is Map
          ? {...emailNotificationTypes, ...parseTypeMap(emailTypes)}
          : null,
      pushNotificationTypes: pushTypes is Map
          ? {...pushNotificationTypes, ...parseTypeMap(pushTypes)}
          : null,
    );
  }

  UserPreferences copyWith({
    String? themeMode,
    bool? showDashboardClock,
    bool? emailNotifications,
    bool? pushNotifications,
    Map<String, bool>? emailNotificationTypes,
    Map<String, bool>? pushNotificationTypes,
  }) {
    return UserPreferences(
      themeMode: themeMode ?? this.themeMode,
      showDashboardClock: showDashboardClock ?? this.showDashboardClock,
      emailNotifications: emailNotifications ?? this.emailNotifications,
      pushNotifications: pushNotifications ?? this.pushNotifications,
      emailNotificationTypes:
          emailNotificationTypes ?? this.emailNotificationTypes,
      pushNotificationTypes: pushNotificationTypes ?? this.pushNotificationTypes,
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
        json['preferences'] is Map ? Map<String, dynamic>.from(json['preferences'] as Map) : null,
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
