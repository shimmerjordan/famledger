import 'package:uuid/uuid.dart';

const Uuid _uuid = Uuid();

/// 新的随机 id（本地生成，服务端幂等键）。
String newId() => _uuid.v4();

/// 记一笔的 clientId：服务端靠它做幂等，离线队列靠它去重。
String newClientId() => _uuid.v4();
