import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:window_manager/window_manager.dart';
import '../services/notification_service.dart';
import '../services/transfer_notification_queue.dart';
import '../services/network_diagnostics.dart';
import '../services/permission_service.dart';
import '../services/share_receiver_service.dart';
import '../utils/device_name.dart';
import '../../features/discovery/discovery_cubit.dart';
import '../../features/transfer/transfer_cubit.dart';
import '../../features/settings/settings_cubit.dart';
import '../../features/history/history_cubit.dart';
import '../../features/chat/chat_cubit.dart';
import '../../features/chat/chat_repository.dart';
import '../../transport/transport_channel.dart';
import '../../transport/transport_factory.dart';
import '../../features/transfer/session/session_repository.dart';
import '../../core/services/transfer_foreground_service.dart';

final getIt = GetIt.instance;

Future<void> initServiceLocator() async {
  final transferBox = await Hive.openBox('transfer_sessions');
  final settingsBox = await Hive.openBox('settings');
  final chatMessagesBox = await Hive.openBox('chat_messages');

  final transport = TransportFactory.create();
  getIt.registerLazySingleton<TransportChannel>(() => transport);

  getIt.registerLazySingleton(() => SessionRepository(transferBox));
  getIt.registerLazySingleton(() => ChatRepository(chatMessagesBox));
  getIt.registerLazySingleton(() => WindowManager.instance);

  final notifications = NotificationService();
  getIt.registerLazySingleton(() => notifications);
  await notifications.initialize();

  // Transfer notifications run through a throttled, non-blocking queue so
  // Android notification I/O can never stall the transfer engine.
  getIt.registerLazySingleton(() => TransferNotificationQueue(notifications));
  getIt.registerLazySingleton(() => NetworkDiagnostics());
  getIt.registerLazySingleton(() => TransferForegroundService());

  getIt.registerLazySingleton(() => PermissionService(notifications));

  final shareReceiver = ShareReceiverService();
  getIt.registerLazySingleton(() => shareReceiver);
  await shareReceiver.initialize();

  final String deviceName =
      settingsBox.get('deviceName', defaultValue: await DeviceName.resolve()) as String;
  transport.setDeviceName(deviceName);

  getIt.registerFactory(() => DiscoveryCubit(getIt()));
  getIt.registerFactory(
    () => TransferCubit(getIt(), getIt(), getIt(), getIt(), getIt(), settingsBox),
  );
  getIt.registerFactory(() => SettingsCubit(settingsBox, transport, defaultDeviceName: deviceName));
  getIt.registerFactory(() => HistoryCubit(getIt()));
  getIt.registerFactory(() => ChatCubit(getIt(), getIt()));
}