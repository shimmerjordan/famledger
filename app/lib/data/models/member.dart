import 'json_utils.dart';

/// 家庭成员 = 登录用户 + 档案。
class Member {
  const Member({
    required this.id,
    required this.username,
    required this.displayName,
    this.color,
    this.avatarEmoji,
    this.role = 'member',
    this.archived = false,
  });

  final String id;
  final String username;
  final String displayName;
  final String? color;
  final String? avatarEmoji;
  final String role;
  final bool archived;

  bool get isAdmin => role == 'admin';

  /// 没设昵称时退回用户名，UI 不该出现空字符串。
  String get label => displayName.isEmpty ? username : displayName;

  factory Member.fromJson(Map<String, dynamic> json) => Member(
    id: jsonString(json['id']),
    username: jsonString(json['username']),
    displayName: jsonString(json['displayName']),
    color: jsonStringOrNull(json['color']),
    avatarEmoji: jsonStringOrNull(json['avatarEmoji']),
    role: jsonString(json['role'], 'member'),
    archived: jsonBool(json['archived']),
  );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'id': id,
      'username': username,
      'displayName': displayName,
    };
    putIfNotNull(json, 'color', color);
    putIfNotNull(json, 'avatarEmoji', avatarEmoji);
    json['role'] = role;
    json['archived'] = archived;
    return json;
  }

  Member copyWith({String? displayName, String? color, String? avatarEmoji, String? role, bool? archived}) =>
      Member(
        id: id,
        username: username,
        displayName: displayName ?? this.displayName,
        color: color ?? this.color,
        avatarEmoji: avatarEmoji ?? this.avatarEmoji,
        role: role ?? this.role,
        archived: archived ?? this.archived,
      );
}
