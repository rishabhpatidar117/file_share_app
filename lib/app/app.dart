import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../core/di/service_locator.dart';
import '../core/services/share_receiver_service.dart';
import '../core/theme/app_theme.dart';
import '../features/home/home_screen.dart';
import '../features/discovery/discovery_cubit.dart';
import '../features/transfer/transfer_cubit.dart';
import '../features/settings/settings_cubit.dart';
import '../features/history/history_cubit.dart';

class SwiftShareApp extends StatelessWidget {
  const SwiftShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => getIt<DiscoveryCubit>()),
        BlocProvider(create: (_) => getIt<TransferCubit>()),
        BlocProvider(create: (_) => getIt<SettingsCubit>()),
        BlocProvider(create: (_) => getIt<HistoryCubit>()),
      ],
      child: BlocBuilder<SettingsCubit, SettingsState>(
        builder: (context, settingsState) {
          return MaterialApp(
            title: 'SwiftShare',
            debugShowCheckedModeBanner: false,
            navigatorKey: getIt<ShareReceiverService>().navigatorKey,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: settingsState.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            home: const _UiReadyGate(child: HomeScreen()),
          );
        },
      ),
    );
  }
}

/// Flips [ShareReceiverService._uiReady] once the first frame is up so a share
/// received on cold start can navigate to the send flow.
class _UiReadyGate extends StatefulWidget {
  final Widget child;
  const _UiReadyGate({required this.child});

  @override
  State<_UiReadyGate> createState() => _UiReadyGateState();
}

class _UiReadyGateState extends State<_UiReadyGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) getIt<ShareReceiverService>().notifyUiReady();
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}