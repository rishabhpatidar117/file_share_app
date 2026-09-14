import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:window_manager/window_manager.dart';
import '../services/notification_service.dart';
import '../services/permission_service.dart';
import '../../features/discovery/discovery_cubit.dart';
import '../../features/transfer/transfer_cubit.dart';
import '../../features/settings/settings_cubit.dart';
import '../../features/history/history_cubit.dart';
import '../../transport/transport_channel.dart';
import '../../transport/transport_factory.dart';
import '../../features/transfer/session/session_repository.dart';

final getIt = GetIt.instance;

Future<void> initServiceLocator() async {
  final transferBox = await Hive.openBox('transfer_sessions');
  final settingsBox = await Hive.openBox('settings');

  final transport = TransportFactory.create();
  getIt.registerLazySingleton<TransportChannel>(() => transport);

  getIt.registerLazySingleton(() => SessionRepository(transferBox));
  getIt.registerLazySingleton(() => WindowManager.instance);

  final notifications = NotificationService();
  getIt.registerLazySingleton(() => notifications);
  await notifications.initialize();

  getIt.registerLazySingleton(() => PermissionService(notifications));

  final deviceName = settingsBox.get('deviceName', defaultValue: 'My Device');
  transport.setDeviceName(deviceName);

  getIt.registerFactory(() => DiscoveryCubit(getIt()));
  getIt.registerFactory(() => TransferCubit(getIt(), getIt(), getIt(), settingsBox));
  getIt.registerFactory(() => SettingsCubit(settingsBox, transport));
  getIt.registerFactory(() => HistoryCubit(getIt()));
}