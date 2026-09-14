export 'network_info_io.dart'
    if (dart.library.js_interop) 'network_info_web.dart'
    if (dart.library.html) 'network_info_web.dart';