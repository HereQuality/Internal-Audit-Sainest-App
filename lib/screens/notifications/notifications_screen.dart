import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/notifications/notification_navigation.dart';
import '../../core/utils/formatters.dart';
import '../../models/notification_model.dart';
import '../../providers/notifications_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationsProvider>().fetchNotifications();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<NotificationsProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (provider.unreadCount > 0)
            TextButton(
              onPressed: () =>
                  context.read<NotificationsProvider>().markAllAsRead(),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: _buildBody(context, provider),
    );
  }

  Widget _buildBody(BuildContext context, NotificationsProvider provider) {
    if (provider.isLoading && provider.notifications.isEmpty) {
      return const AppLoading();
    }
    if (provider.errorMessage != null && provider.notifications.isEmpty) {
      return ErrorState(
        message: provider.errorMessage!,
        onRetry: () =>
            context.read<NotificationsProvider>().fetchNotifications(),
      );
    }
    if (provider.notifications.isEmpty) {
      return const EmptyState(
        icon: Icons.notifications_none_rounded,
        title: 'No notifications yet',
        subtitle: 'You are all caught up.',
      );
    }
    return RefreshIndicator(
      onRefresh: () =>
          context.read<NotificationsProvider>().fetchNotifications(),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: provider.notifications.length,
        separatorBuilder: (context, index) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final notification = provider.notifications[index];
          return _NotificationTile(notification: notification);
        },
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final NotificationModel notification;

  const _NotificationTile({required this.notification});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: () {
        context.read<NotificationsProvider>().markAsRead(notification.id);
        openNotificationTarget(
          context,
          type: notification.type,
          referenceId: notification.referenceId,
        );
      },
      leading: CircleAvatar(
        backgroundColor: notification.isRead
            ? scheme.surfaceContainerHighest
            : scheme.primaryContainer,
        child: Icon(
          Icons.notifications_outlined,
          color: notification.isRead
              ? scheme.outline
              : scheme.onPrimaryContainer,
          size: 20,
        ),
      ),
      title: Text(
        notification.title,
        style: TextStyle(
          fontWeight: notification.isRead ? FontWeight.w500 : FontWeight.w700,
        ),
      ),
      subtitle: Text(
        notification.message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        Formatters.relative(notification.createdAt),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.outline),
      ),
    );
  }
}
