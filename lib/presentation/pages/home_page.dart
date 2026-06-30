import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';

import '../../core/platform/window_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/email_folder.dart';
import '../../domain/entities/email.dart';
import '../../domain/usecases/get_email.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/calendar/calendar_bloc.dart';
import '../blocs/calendar/calendar_event.dart';
import '../blocs/tasks/tasks_bloc.dart';
import '../blocs/tasks/tasks_event.dart';
import '../blocs/email_detail/email_detail_bloc.dart';
import '../blocs/email_detail/email_detail_event.dart';
import '../blocs/email_list/email_list_bloc.dart';
import '../blocs/email_list/email_list_event.dart';
import '../blocs/folder_list/folder_list_bloc.dart';
import '../blocs/folder_list/folder_list_event.dart';
import '../blocs/folder_list/folder_list_state.dart';
import '../blocs/home/home_cubit.dart';
import '../blocs/mail_poller/mail_poller_cubit.dart';
import '../blocs/mail_poller/mail_poller_state.dart';
import '../blocs/ai/ai_folder_cubit.dart';
import '../blocs/email_list/email_list_state.dart';
import '../widgets/ai_day_panel.dart';
import '../widgets/email_list_panel.dart';
import '../widgets/folder_panel.dart';
import '../widgets/reading_pane.dart';
import 'calendar_page.dart';
import 'tasks_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider.value(value: sl<AccountCubit>()),
        BlocProvider.value(
          value: sl<MailPollerCubit>()..initialize(),
        ),
        BlocProvider(
          create: (_) =>
              sl<FolderListBloc>()..add(const FolderListLoadRequested()),
        ),
        BlocProvider(create: (_) => sl<EmailListBloc>()),
        BlocProvider(create: (_) => sl<EmailDetailBloc>()),
        BlocProvider(create: (_) => HomeCubit()),
        BlocProvider(create: (_) => sl<AiFolderCubit>()),
        BlocProvider(create: (_) => sl<CalendarBloc>()),
        BlocProvider(
          create: (_) =>
              sl<TasksBloc>()..add(const TasksLoadRequested()),
        ),
      ],
      child: const _HomeView(),
    );
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView();

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<AccountCubit, AccountState>(
          listenWhen: (prev, curr) {
            if (prev is AccountsLoaded && curr is AccountsLoaded) {
              return prev.activeAccount.id != curr.activeAccount.id;
            }
            return false;
          },
          listener: (context, _) {
            context.read<HomeCubit>().clearFolder();
            context.read<FolderListBloc>().add(const FolderListLoadRequested());
            context.read<EmailListBloc>().add(const EmailListCleared());
            context.read<EmailDetailBloc>().add(const EmailDetailCleared());
            context.read<CalendarBloc>().add(const CalendarCleared());
          },
        ),
        BlocListener<AccountCubit, AccountState>(
          listenWhen: (_, curr) => curr is AccountNoAccounts,
          listener: (context, _) {
            context.read<HomeCubit>().clearFolder();
            context.read<EmailListBloc>().add(const EmailListCleared());
            context.read<EmailDetailBloc>().add(const EmailDetailCleared());
            context.read<CalendarBloc>().add(const CalendarCleared());
          },
        ),
        BlocListener<FolderListBloc, FolderListState>(
          listenWhen: (prev, curr) => curr is FolderListLoaded,
          listener: (context, state) {
            if (state is FolderListLoaded) {
              final homeCubit = context.read<HomeCubit>();
              if (homeCubit.state.selectedFolderId != null) return;

              final inbox = state.folders.firstWhere(
                (f) => f.displayName.toLowerCase() == 'inbox',
                orElse: () => state.folders.first,
              );

              homeCubit.selectFolder(inbox.id);
              context.read<EmailListBloc>().add(
                    EmailListLoadRequested(
                      folderId: inbox.id,
                      folderDisplayName: inbox.displayName,
                    ),
                  );
            }
          },
        ),
        BlocListener<FolderListBloc, FolderListState>(
          listenWhen: (_, curr) =>
              curr is FolderListLoaded && !curr.isRefreshing,
          listener: (context, state) {
            if (state is! FolderListLoaded) return;
            final inboxes = state.folders.where(
              (f) => f.displayName.toLowerCase() == 'inbox',
            );
            if (inboxes.isEmpty) return;
            context
                .read<MailPollerCubit>()
                .updateBadgeFromFolders(inboxes.first.unreadItemCount);
          },
        ),
        BlocListener<MailPollerCubit, MailPollerState>(
          listenWhen: (prev, curr) =>
              prev.pollGeneration != curr.pollGeneration,
          listener: (context, _) {
            context
                .read<EmailListBloc>()
                .add(const EmailListRefreshRequested());
            context
                .read<FolderListBloc>()
                .add(const FolderListLoadRequested());
          },
        ),
      ],
      child: Scaffold(
        backgroundColor: context.colors.surfaceBase,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 600) {
                return const _MobileLayout();
              }
              return const _ThreePanelLayout();
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile single-pane navigation
// ---------------------------------------------------------------------------

enum _MobileStep { folders, emailList, readingPane }

class _MobileLayout extends StatefulWidget {
  const _MobileLayout();

  @override
  State<_MobileLayout> createState() => _MobileLayoutState();
}

class _MobileLayoutState extends State<_MobileLayout> {
  _MobileStep _step = _MobileStep.folders;

  void _back() {
    setState(() {
      switch (_step) {
        case _MobileStep.folders:
          break;
        case _MobileStep.emailList:
          _step = _MobileStep.folders;
        case _MobileStep.readingPane:
          _step = _MobileStep.emailList;
          context.read<HomeCubit>().clearEmail();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == _MobileStep.folders,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: BlocBuilder<HomeCubit, HomeState>(
        builder: (context, homeState) {
          return BlocBuilder<FolderListBloc, FolderListState>(
            builder: (context, folderState) {
              final selectedFolder = _resolveFolder(homeState, folderState);
              final accountState = context.read<AccountCubit>().state;
              final accountId = accountState is AccountsLoaded
                  ? accountState.activeAccount.id
                  : '';
              final homeCubit = context.read<HomeCubit>();

              void onEmailSelected(Email email) {
                homeCubit.selectEmail(email.id);
                context.read<EmailDetailBloc>().add(
                      EmailDetailLoadRequested(emailId: email.id),
                    );
                if (!email.isRead) {
                  context.read<EmailListBloc>().add(
                        EmailListMarkReadRequested(
                            emailId: email.id, isRead: true),
                      );
                  if (selectedFolder != null) {
                    context.read<FolderListBloc>().add(
                          FolderListUnreadCountChanged(
                            folderId: selectedFolder.id,
                            unreadCountDelta: -1,
                          ),
                        );
                  }
                  context.read<MailPollerCubit>().decrementUnreadCount();
                }
                setState(() => _step = _MobileStep.readingPane);
              }

              return switch (_step) {
                _MobileStep.folders => FolderPanel(
                    key: ValueKey(accountId),
                    selectedFolderId: homeState.selectedFolderId,
                    initialExpandedIds:
                        homeCubit.savedExpandedForAccount(accountId),
                    onExpandedIdsChanged: (ids) {
                      final s = context.read<AccountCubit>().state;
                      if (s is AccountsLoaded) {
                        homeCubit.rememberExpandedForAccount(
                            s.activeAccount.id, ids);
                      }
                    },
                    onFolderSelected: (folder) {
                      homeCubit.selectFolder(folder.id);
                      context
                          .read<EmailDetailBloc>()
                          .add(const EmailDetailCleared());
                      context.read<EmailListBloc>().add(
                            EmailListLoadRequested(
                              folderId: folder.id,
                              folderDisplayName: folder.displayName,
                            ),
                          );
                      setState(() => _step = _MobileStep.emailList);
                    },
                    onCalendarTapped: () {},
                    onTasksTapped: () {},
                    onAiTapped: () {},
                  ),
                _MobileStep.emailList => EmailListPanel(
                    folderName: selectedFolder?.displayName ?? 'Inbox',
                    folder: selectedFolder,
                    selectedEmailId: homeState.selectedEmailId,
                    onEmailSelected: onEmailSelected,
                    onBack: _back,
                  ),
                _MobileStep.readingPane => ReadingPane(onBack: _back),
              };
            },
          );
        },
      ),
    );
  }

  EmailFolder? _resolveFolder(
      HomeState homeState, FolderListState folderListState) {
    if (homeState.selectedFolderId == null) return null;
    if (folderListState is FolderListLoaded) {
      try {
        return folderListState.folders
            .firstWhere((f) => f.id == homeState.selectedFolderId);
      } catch (_) {}
    }
    return null;
  }
}

// ---------------------------------------------------------------------------

class _ThreePanelLayout extends StatefulWidget {
  const _ThreePanelLayout();

  @override
  State<_ThreePanelLayout> createState() => _ThreePanelLayoutState();
}

class _ThreePanelLayoutState extends State<_ThreePanelLayout> {
  double _folderWidth = 220;
  double _emailListWidth = 320;
  double _calendarPaneWidth = 300;

  static const double _minPanelWidth = 120;
  static const double _minReadingPaneWidth = 200;
  static const double _minCalendarPaneWidth = 200;
  static const double _handleWidth = 8;
  static const _calendarRefreshChannel =
      MethodChannel('au.com.sharpblue.nightmail/calendar_refresh');

  @override
  void initState() {
    super.initState();
    _calendarRefreshChannel.setMethodCallHandler((call) async {
      if (call.method == 'eventSaved' && mounted) {
        final bloc = context.read<CalendarBloc>();
        bloc.add(CalendarWeekNavigated(weekStart: bloc.state.weekStart));
      }
    });
  }

  @override
  void dispose() {
    _calendarRefreshChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<HomeCubit, HomeState>(
      builder: (context, homeState) {
        return BlocBuilder<FolderListBloc, FolderListState>(
          builder: (context, folderListState) {
            return _buildLayout(context, homeState, folderListState);
          },
        );
      },
    );
  }

  Widget _buildLayout(
    BuildContext context,
    HomeState homeState,
    FolderListState folderListState,
  ) {
    final selectedFolder = _resolveFolder(homeState, folderListState);

    void onEmailSelected(Email email) {
      context.read<HomeCubit>().selectEmail(email.id);
      context.read<EmailDetailBloc>().add(
            EmailDetailLoadRequested(emailId: email.id),
          );
      if (!email.isRead) {
        context.read<EmailListBloc>().add(
              EmailListMarkReadRequested(emailId: email.id, isRead: true),
            );
        if (selectedFolder != null) {
          context.read<FolderListBloc>().add(
                FolderListUnreadCountChanged(
                  folderId: selectedFolder.id,
                  unreadCountDelta: -1,
                ),
              );
        }
        context.read<MailPollerCubit>().decrementUnreadCount();
      }
    }

    final isDraftsFolder =
        selectedFolder?.displayName.toLowerCase() == 'drafts';

    void onEmailDoubleTapped(Email email) async {
      // Fetch the full email body (list items only carry the preview).
      final result =
          await sl<GetEmail>()(GetEmailParams(id: email.id));
      final full = result.getOrElse((_) => email);

      if (isDraftsFolder) {
        createSubWindow(
          WindowConfiguration(
            arguments: jsonEncode({
              'mode': 'newEmail',
              'existingDraftId': full.id,
              'draftEmail': {
                'subject': full.subject,
                'toRecipients': full.toRecipients
                    .map((r) => {'address': r.address, 'name': r.name})
                    .toList(),
                'ccRecipients': full.ccRecipients
                    .map((r) => {'address': r.address, 'name': r.name})
                    .toList(),
                'body': full.body,
                'bodyType': full.bodyType.name,
              },
            }),
          ),
        );
      } else {
        createSubWindow(
          WindowConfiguration(
            arguments: jsonEncode({
              'type': 'emailView',
              'email': {
                'id': full.id,
                'subject': full.subject,
                'from': {
                  'address': full.from.address,
                  'name': full.from.name,
                },
                'toRecipients': full.toRecipients
                    .map((r) => {'address': r.address, 'name': r.name})
                    .toList(),
                'ccRecipients': full.ccRecipients
                    .map((r) => {'address': r.address, 'name': r.name})
                    .toList(),
                'body': full.body,
                'bodyType': full.bodyType.name,
                'receivedDateTime':
                    full.receivedDateTime.toIso8601String(),
              },
            }),
          ),
        );
      }
    }

    return LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth = constraints.maxWidth;
            const totalHandleWidth = _handleWidth * 2;

            // In 4-panel views (tasks / calendar), clamp the side-panel width so the
            // fixed children never exceed totalWidth regardless of initial defaults.
            final calendarWidth = _calendarPaneWidth.clamp(
              0.0,
              (totalWidth - _handleWidth * 3 - _folderWidth - _emailListWidth)
                  .clamp(0.0, double.infinity),
            );

            final accountState = context.read<AccountCubit>().state;
            final accountId = accountState is AccountsLoaded
                ? accountState.activeAccount.id
                : '';
            final homeCubit = context.read<HomeCubit>();

            final folderPanel = FolderPanel(
              key: ValueKey(accountId),
              selectedFolderId: homeState.selectedFolderId,
              initialExpandedIds: homeCubit.savedExpandedForAccount(accountId),
              onExpandedIdsChanged: (ids) {
                final state = context.read<AccountCubit>().state;
                if (state is AccountsLoaded) {
                  homeCubit.rememberExpandedForAccount(
                      state.activeAccount.id, ids);
                }
              },
              onFolderSelected: (folder) {
                homeCubit.selectFolder(folder.id);
                context.read<EmailDetailBloc>().add(const EmailDetailCleared());
                context.read<EmailListBloc>().add(
                      EmailListLoadRequested(
                        folderId: folder.id,
                        folderDisplayName: folder.displayName,
                      ),
                    );
              },
              onCalendarTapped: () {
                if (homeState.view == HomeView.calendar) {
                  homeCubit.showEmail();
                } else {
                  homeCubit.showCalendar();
                  final monday = _mondayOfWeek(DateTime.now());
                  context.read<CalendarBloc>().add(
                        CalendarWeekLoadRequested(weekStart: monday),
                      );
                }
              },
              onTasksTapped: () {
                if (homeState.view == HomeView.tasks) {
                  homeCubit.showEmail();
                } else {
                  homeCubit.showTasks();
                }
              },
              onAiTapped: () {
                if (homeState.view == HomeView.ai) {
                  homeCubit.showEmail();
                } else {
                  homeCubit.showAi();
                }
              },
            );

            if (homeState.view == HomeView.ai) {
              return Row(
                children: [
                  SizedBox(width: _folderWidth, child: folderPanel),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _emailListWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _folderWidth =
                            (_folderWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: _emailListWidth,
                    child: EmailListPanel(
                      folderName: selectedFolder?.displayName ?? 'Inbox',
                      folder: selectedFolder,
                      selectedEmailId: homeState.selectedEmailId,
                      onEmailSelected: onEmailSelected,
                      onEmailDoubleTapped: onEmailDoubleTapped,
                    ),
                  ),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _emailListWidth =
                            (_emailListWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  const Expanded(child: ReadingPane()),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _emailListWidth -
                            _minReadingPaneWidth;
                        _calendarPaneWidth = (_calendarPaneWidth - delta)
                            .clamp(_minCalendarPaneWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: calendarWidth,
                    child: AiDayPanel(
                      onClose: () => context.read<HomeCubit>().showEmail(),
                      folderIdProvider: () {
                        final listState =
                            context.read<EmailListBloc>().state;
                        return listState is EmailListLoaded
                            ? listState.currentFolderId
                            : null;
                      },
                      contextProvider: () {
                        final listState =
                            context.read<EmailListBloc>().state;
                        if (listState is! EmailListLoaded ||
                            listState.emails.isEmpty) {
                          return null;
                        }
                        return _formatFolderEmailsForAi(listState.emails);
                      },
                    ),
                  ),
                ],
              );
            }

            if (homeState.view == HomeView.tasks) {
              return Row(
                children: [
                  SizedBox(width: _folderWidth, child: folderPanel),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _emailListWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _folderWidth =
                            (_folderWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: _emailListWidth,
                    child: EmailListPanel(
                      folderName: selectedFolder?.displayName ?? 'Inbox',
                      folder: selectedFolder,
                      selectedEmailId: homeState.selectedEmailId,
                      onEmailSelected: onEmailSelected,
                      onEmailDoubleTapped: onEmailDoubleTapped,
                    ),
                  ),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _emailListWidth =
                            (_emailListWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  const Expanded(child: ReadingPane()),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _emailListWidth -
                            _minReadingPaneWidth;
                        _calendarPaneWidth = (_calendarPaneWidth - delta)
                            .clamp(_minCalendarPaneWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: calendarWidth,
                    child: TasksDayPanel(
                      onClose: () => context.read<HomeCubit>().showEmail(),
                    ),
                  ),
                ],
              );
            }

            if (homeState.view == HomeView.calendar) {
              return Row(
                children: [
                  SizedBox(width: _folderWidth, child: folderPanel),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _emailListWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _folderWidth =
                            (_folderWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: _emailListWidth,
                    child: EmailListPanel(
                      folderName: selectedFolder?.displayName ?? 'Inbox',
                      folder: selectedFolder,
                      selectedEmailId: homeState.selectedEmailId,
                      onEmailSelected: onEmailSelected,
                      onEmailDoubleTapped: onEmailDoubleTapped,
                    ),
                  ),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _minReadingPaneWidth -
                            _calendarPaneWidth;
                        _emailListWidth =
                            (_emailListWidth + delta).clamp(_minPanelWidth, max);
                      });
                    },
                  ),
                  const Expanded(child: ReadingPane()),
                  _ResizeHandle(
                    onDrag: (delta) {
                      setState(() {
                        final max = totalWidth -
                            _handleWidth * 3 -
                            _folderWidth -
                            _emailListWidth -
                            _minReadingPaneWidth;
                        _calendarPaneWidth = (_calendarPaneWidth - delta)
                            .clamp(_minCalendarPaneWidth, max);
                      });
                    },
                  ),
                  SizedBox(
                    width: calendarWidth,
                    child: CalendarDayPanel(
                      onClose: () =>
                          context.read<HomeCubit>().showEmail(),
                    ),
                  ),
                ],
              );
            }

            return Row(
              children: [
                SizedBox(width: _folderWidth, child: folderPanel),
                _ResizeHandle(
                  onDrag: (delta) {
                    setState(() {
                      final maxWidth = totalWidth -
                          totalHandleWidth -
                          _emailListWidth -
                          _minReadingPaneWidth;
                      _folderWidth =
                          (_folderWidth + delta).clamp(_minPanelWidth, maxWidth);
                    });
                  },
                ),
                SizedBox(
                  width: _emailListWidth,
                  child: EmailListPanel(
                    folderName: selectedFolder?.displayName ?? 'Inbox',
                    folder: selectedFolder,
                    selectedEmailId: homeState.selectedEmailId,
                    onEmailSelected: onEmailSelected,
                    onEmailDoubleTapped: onEmailDoubleTapped,
                  ),
                ),
                _ResizeHandle(
                  onDrag: (delta) {
                    setState(() {
                      final maxWidth = totalWidth -
                          totalHandleWidth -
                          _folderWidth -
                          _minReadingPaneWidth;
                      _emailListWidth = (_emailListWidth + delta)
                          .clamp(_minPanelWidth, maxWidth);
                    });
                  },
                ),
                const Expanded(child: ReadingPane()),
              ],
            );
          },
        );
  }

  static DateTime _mondayOfWeek(DateTime date) {
    final daysFromMonday = (date.weekday - 1) % 7;
    return DateTime(date.year, date.month, date.day - daysFromMonday);
  }

  EmailFolder? _resolveFolder(HomeState homeState, FolderListState folderListState) {
    if (homeState.selectedFolderId == null) return null;
    if (folderListState is FolderListLoaded) {
      try {
        return folderListState.folders
            .firstWhere((f) => f.id == homeState.selectedFolderId);
      } catch (_) {}
    }
    return null;
  }
}

class _ResizeHandle extends StatefulWidget {
  final ValueChanged<double> onDrag;

  const _ResizeHandle({required this.onDrag});

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerMove: (event) => widget.onDrag(event.delta.dx),
        child: SizedBox(
          width: 8,
          child: Center(
            child: Container(
              width: 1,
              color: _hovered
                  ? context.colors.textDimmed
                  : context.colors.separator,
            ),
          ),
        ),
      ),
    );
  }
}

/// Formats up to 25 emails from the current folder into a compact text block
/// for use as AI context. Uses subject/from/date/preview only to stay within
/// token budget and avoid sending full bodies.
String _formatFolderEmailsForAi(List<Email> emails) {
  final buffer = StringBuffer();
  final capped = emails.take(25);
  var index = 1;
  for (final email in capped) {
    buffer.writeln('[Email $index]');
    buffer.writeln('From: ${email.from.displayName}');
    buffer.writeln('Subject: ${email.subject}');
    buffer.writeln('Date: ${email.receivedDateTime.toLocal()}');
    if (email.bodyPreview.isNotEmpty) {
      buffer.writeln('Preview: ${email.bodyPreview}');
    }
    buffer.writeln();
    index++;
  }
  return buffer.toString().trimRight();
}
