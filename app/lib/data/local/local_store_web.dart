import 'package:shared_preferences/shared_preferences.dart';

import 'local_store.dart';

/// Web 没有可写目录，缓存落 localStorage。
Future<LocalStore> openDefaultStore() async =>
    PrefsLocalStore(await SharedPreferences.getInstance());
