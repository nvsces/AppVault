import 'package:flutter/material.dart';

import '../state/job.dart';
import 'widgets.dart';

class JobsPage extends StatelessWidget {
  const JobsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Задачи',
          actions: [
            TextButton(
              onPressed: store.jobs.every((j) => j.isRunning) ? null : store.clearFinishedJobs,
              child: const Text('Очистить завершённые'),
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: store.jobs.isEmpty
              ? const EmptyState(
                  icon: Icons.list_alt,
                  title: 'Задач нет',
                  text: 'Здесь появляются импорт, скачивание, переподпись и установка — с прогрессом и журналом.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.page, vertical: 8),
                  itemCount: store.jobs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => JobRow(key: ValueKey(store.jobs[i].id), job: store.jobs[i]),
                ),
        ),
      ],
    );
  }
}

class JobRow extends StatefulWidget {
  const JobRow({super.key, required this.job});
  final Job job;

  @override
  State<JobRow> createState() => _JobRowState();
}

class _JobRowState extends State<JobRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.job,
    builder: (context, _) {
      final job = widget.job;
      final failed = job.state == JobState.failed;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox(width: 22, child: _icon(job)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(job.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      SelectableText(
                        failed ? (job.error ?? '') : job.status,
                        maxLines: _expanded ? null : 1,
                        style: TextStyle(fontSize: 12, color: failed ? Colors.red : Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Muted(formatTime(job.started), small: true),
                if (job.isRunning) TextButton(onPressed: job.cancel, child: const Text('Отменить')),
                IconButton(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                ),
              ],
            ),
            if (job.isRunning)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(value: job.progress),
              ),
            if (_expanded)
              Container(
                margin: const EdgeInsets.only(top: 8),
                constraints: const BoxConstraints(maxHeight: 240),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(job.log.join('\n'), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
                ),
              ),
          ],
        ),
      );
    },
  );

  Widget _icon(Job job) => switch (job.state) {
    JobState.running => const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
    JobState.succeeded => const Icon(Icons.check_circle, color: Colors.green, size: 20),
    JobState.cancelled => const Icon(Icons.remove_circle, color: Colors.grey, size: 20),
    JobState.failed => const Icon(Icons.error, color: Colors.red, size: 20),
  };
}
