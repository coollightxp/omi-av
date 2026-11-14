/// Web 端无法使用 dart:io，预连接为空操作（浏览器自带连接池，切台本就不慢）
Future<void> warmHost(String host, int port,
        {Duration timeout = const Duration(milliseconds: 1500)}) async {}
