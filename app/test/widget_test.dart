import 'package:flutter_test/flutter_test.dart';

import 'package:ide_claw/main.dart';

void main() {
  testWidgets('IDEClawApp 构造冒烟测试', (WidgetTester tester) async {
    // 仅验证 widget 树能在没有 LocalIpcService 注入时正常构造，不进入网络/平台插件路径
    await tester.pumpWidget(const IDEClawApp());
    expect(find.byType(IDEClawApp), findsOneWidget);
  });
}
