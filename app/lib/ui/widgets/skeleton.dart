import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// 加载态用骨架块，不用居中转圈（DESIGN.md）。
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = 6,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统「移除动画」时就是一块静止的灰条。
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 0.5;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ledger = LedgerColors.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(ledger.surface2, ledger.surface3, _controller.value),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// 列表加载：几行长短不一的骨架条。
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 5, this.padding});

  final int rows;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding ?? const EdgeInsets.all(LedgerLayout.pagePadding),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows; i++) ...[
          Row(
            children: [
              const Skeleton(width: 36, height: 36, radius: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Skeleton(width: 120 + (i % 3) * 40, height: 14),
                    const SizedBox(height: 8),
                    const Skeleton(width: 80, height: 12),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Skeleton(width: 64, height: 16),
            ],
          ),
          if (i != rows - 1) const SizedBox(height: 20),
        ],
      ],
    ),
  );
}
