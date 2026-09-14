import 'package:flutter/material.dart';

/// DESIGN.md 里那些不属于 M3 `ColorScheme` 的语义色。
@immutable
class LedgerColors extends ThemeExtension<LedgerColors> {
  const LedgerColors({
    required this.income,
    required this.incomeContainer,
    required this.warning,
    required this.warningContainer,
    required this.surface2,
    required this.surface3,
    required this.fundPalette,
  });

  /// 收入金额 `+¥`（支出不着色，只带 `−`）。
  final Color income;
  final Color incomeContainer;

  /// 预算接近上限、待确认。
  final Color warning;
  final Color warningContainer;

  /// 导航栏/工具栏/面板。
  final Color surface2;

  /// 输入框底、分隔块。
  final Color surface3;

  /// 基金身份色 12 色盘。
  final List<Color> fundPalette;

  /// 按顺序取一个基金色（基金没自定义颜色时用）。
  Color fundColor(int index) =>
      fundPalette[index.abs() % fundPalette.length];

  static LedgerColors of(BuildContext context) =>
      Theme.of(context).extension<LedgerColors>() ?? light;

  static const LedgerColors light = LedgerColors(
    income: Color(0xFF16805E),
    incomeContainer: Color(0xFFCDF6E3),
    warning: Color(0xFFD0901E),
    warningContainer: Color(0xFFFFEAC2),
    surface2: Color(0xFFF2F3F6),
    surface3: Color(0xFFE5E8EC),
    fundPalette: [
      Color(0xFFC36A4F),
      Color(0xFFB07A20),
      Color(0xFF8B8C27),
      Color(0xFF4A9A5E),
      Color(0xFF009D82),
      Color(0xFF009BA3),
      Color(0xFF1292C0),
      Color(0xFF5A86CE),
      Color(0xFF8678C9),
      Color(0xFFA66DB3),
      Color(0xFFBB6690),
      Color(0xFFC3656F),
    ],
  );

  static const LedgerColors dark = LedgerColors(
    income: Color(0xFF5FC199),
    incomeContainer: Color(0xFF043726),
    warning: Color(0xFFEEB154),
    warningContainer: Color(0xFF4F3000),
    surface2: Color(0xFF1B1C1E),
    surface3: Color(0xFF26272A),
    fundPalette: [
      Color(0xFFE79277),
      Color(0xFFD3A056),
      Color(0xFFAFB15B),
      Color(0xFF76BE86),
      Color(0xFF51C1A7),
      Color(0xFF3EBFC6),
      Color(0xFF57B8E3),
      Color(0xFF82ACF0),
      Color(0xFFAA9FEC),
      Color(0xFFCA94D6),
      Color(0xFFDF8DB5),
      Color(0xFFE88D94),
    ],
  );

  @override
  LedgerColors copyWith({
    Color? income,
    Color? incomeContainer,
    Color? warning,
    Color? warningContainer,
    Color? surface2,
    Color? surface3,
    List<Color>? fundPalette,
  }) => LedgerColors(
    income: income ?? this.income,
    incomeContainer: incomeContainer ?? this.incomeContainer,
    warning: warning ?? this.warning,
    warningContainer: warningContainer ?? this.warningContainer,
    surface2: surface2 ?? this.surface2,
    surface3: surface3 ?? this.surface3,
    fundPalette: fundPalette ?? this.fundPalette,
  );

  @override
  LedgerColors lerp(ThemeExtension<LedgerColors>? other, double t) {
    if (other is! LedgerColors) return this;
    return LedgerColors(
      income: Color.lerp(income, other.income, t)!,
      incomeContainer: Color.lerp(incomeContainer, other.incomeContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      fundPalette: [
        for (var i = 0; i < fundPalette.length; i++)
          Color.lerp(fundPalette[i], other.fundPalette[i], t)!,
      ],
    );
  }
}

/// 圆角：卡片/面板 12、按钮/输入 10、芯片 8、FAB 16（DESIGN.md）。
class LedgerShapes {
  const LedgerShapes._();

  static const double card = 12;
  static const double control = 10;
  static const double chip = 8;
  static const double fab = 16;

  static final RoundedRectangleBorder cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(card),
  );
  static final RoundedRectangleBorder controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(control),
  );
}

/// 页边距与断点（DESIGN.md「Layout」）。
class LedgerLayout {
  const LedgerLayout._();

  /// < 600：底部导航 + FAB。
  static const double compact = 600;

  /// 600–839：导航轨 + 单栏。
  static const double medium = 840;

  static const double pagePadding = 16;
  static const double widePagePadding = 24;
  static const double groupGap = 24;
  static const double itemGap = 12;

  /// 宽屏内容不要拉得太开。
  static const double maxContentWidth = 1200;

  static bool isCompact(double width) => width < compact;
  static bool isExpanded(double width) => width >= medium;
}

const List<String> _cjkFallback = [
  'PingFang SC',
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'Microsoft YaHei',
  'Heiti SC',
];

const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

/// 金额一律等宽数字；其余沿用 M3 type scale。
TextTheme _textTheme(Color ink, Color muted) {
  const money = _tabular;
  return TextTheme(
    displayLarge: TextStyle(fontSize: 57, fontWeight: FontWeight.w600, color: ink, fontFeatures: money),
    displayMedium: TextStyle(fontSize: 45, fontWeight: FontWeight.w600, color: ink, fontFeatures: money),
    displaySmall: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, color: ink, fontFeatures: money),
    headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w600, color: ink, fontFeatures: money),
    headlineMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: ink, fontFeatures: money),
    headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: ink, fontFeatures: money),
    titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: ink, fontFeatures: money),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ink),
    titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ink),
    bodyLarge: TextStyle(fontSize: 16, color: ink),
    bodyMedium: TextStyle(fontSize: 14, color: ink),
    bodySmall: TextStyle(fontSize: 12, color: muted),
    labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ink),
    labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: muted),
    labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: muted),
  );
}

const ColorScheme _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFFC25430),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFFFE3D8),
  onPrimaryContainer: Color(0xFF5B1A03),
  secondary: Color(0xFF5F636A),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFE5E8EC),
  onSecondaryContainer: Color(0xFF161616),
  tertiary: Color(0xFF16805E),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFCDF6E3),
  onTertiaryContainer: Color(0xFF063D2C),
  error: Color(0xFFC92F33),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFFDFDA),
  onErrorContainer: Color(0xFF5A1113),
  surface: Color(0xFFFFFFFF),
  onSurface: Color(0xFF161616),
  onSurfaceVariant: Color(0xFF5F636A),
  surfaceDim: Color(0xFFDFE1E5),
  surfaceBright: Color(0xFFFFFFFF),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF7F8FA),
  surfaceContainer: Color(0xFFF2F3F6),
  surfaceContainerHigh: Color(0xFFECEDF1),
  surfaceContainerHighest: Color(0xFFE5E8EC),
  outline: Color(0xFFCFD1D5),
  outlineVariant: Color(0xFFE5E8EC),
  inverseSurface: Color(0xFF2B2C2F),
  onInverseSurface: Color(0xFFF2F3F6),
  inversePrimary: Color(0xFFF08C6D),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

const ColorScheme _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFF08C6D),
  onPrimary: Color(0xFF3A1206),
  primaryContainer: Color(0xFF571E0B),
  onPrimaryContainer: Color(0xFFFFDACD),
  secondary: Color(0xFF9A9FA6),
  onSecondary: Color(0xFF1B1C1E),
  secondaryContainer: Color(0xFF26272A),
  onSecondaryContainer: Color(0xFFEBEBEB),
  tertiary: Color(0xFF5FC199),
  onTertiary: Color(0xFF04291C),
  tertiaryContainer: Color(0xFF043726),
  onTertiaryContainer: Color(0xFFCDF6E3),
  error: Color(0xFFFD736D),
  onError: Color(0xFF3A0A08),
  errorContainer: Color(0xFF621D1C),
  onErrorContainer: Color(0xFFFFDAD6),
  surface: Color(0xFF141414),
  onSurface: Color(0xFFEBEBEB),
  onSurfaceVariant: Color(0xFF9A9FA6),
  surfaceDim: Color(0xFF141414),
  surfaceBright: Color(0xFF3A3B3E),
  surfaceContainerLowest: Color(0xFF0F0F10),
  surfaceContainerLow: Color(0xFF1B1C1E),
  surfaceContainer: Color(0xFF1F2022),
  surfaceContainerHigh: Color(0xFF26272A),
  surfaceContainerHighest: Color(0xFF2E3033),
  outline: Color(0xFF313336),
  outlineVariant: Color(0xFF26272A),
  inverseSurface: Color(0xFFEBEBEB),
  onInverseSurface: Color(0xFF1B1C1E),
  inversePrimary: Color(0xFFC25430),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

/// 页面转场：fade-through；系统开了「移除动画」就瞬切。
class FadeThroughPageTransitions extends PageTransitionsBuilder {
  const FadeThroughPageTransitions();

  static const FadeForwardsPageTransitionsBuilder _inner =
      FadeForwardsPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return _inner.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// 浅色与深色都是一等公民，默认跟随系统。
ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final scheme = isDark ? _darkScheme : _lightScheme;
  final ledger = isDark ? LedgerColors.dark : LedgerColors.light;
  final text = _textTheme(scheme.onSurface, scheme.onSurfaceVariant);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    canvasColor: scheme.surface,
    fontFamilyFallback: _cjkFallback,
    textTheme: text,
    extensions: [ledger],
    splashFactory: InkSparkle.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeThroughPageTransitions(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeThroughPageTransitions(),
        TargetPlatform.linux: FadeThroughPageTransitions(),
        TargetPlatform.fuchsia: FadeThroughPageTransitions(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: ledger.surface2,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleMedium,
    ),
    // 不用投影表达层级：surface2/surface3 + 1px 描边。
    cardTheme: CardThemeData(
      color: ledger.surface2,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.card),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall,
      minVerticalPadding: 12,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: LedgerShapes.controlShape,
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: LedgerShapes.controlShape,
        side: BorderSide(color: scheme.outline),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 44),
        shape: LedgerShapes.controlShape,
        textStyle: text.labelLarge,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ledger.surface3,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.control),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.control),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.control),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.control),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.control),
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: ledger.surface2,
      selectedColor: scheme.primaryContainer,
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: text.labelLarge,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.chip),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.fab),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: ledger.surface2,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      elevation: 0,
      height: 68,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? text.labelMedium?.copyWith(color: scheme.onSurface)
            : text.labelMedium,
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: ledger.surface2,
      indicatorColor: scheme.primaryContainer,
      selectedLabelTextStyle: text.labelMedium?.copyWith(color: scheme.onSurface),
      unselectedLabelTextStyle: text.labelMedium,
      selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer, size: 24),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 24),
      useIndicator: true,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onInverseSurface),
      shape: LedgerShapes.controlShape,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LedgerShapes.card + 4),
      ),
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: ledger.surface3,
      circularTrackColor: ledger.surface3,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: scheme.primary,
      inactiveTrackColor: ledger.surface3,
      thumbColor: scheme.primary,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onPrimary
            : scheme.onSurfaceVariant,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : ledger.surface3,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(LedgerShapes.chip),
      ),
      textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
    ),
  );
}

ThemeData get lightTheme => buildTheme(Brightness.light);
ThemeData get darkTheme => buildTheme(Brightness.dark);
