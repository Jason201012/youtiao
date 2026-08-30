import 'package:flutter_test/flutter_test.dart';
import 'package:todolist/services/backup_crypto.dart';

void main() {
  const plain = '{"tasks":[{"id":1,"title":"买牛奶"}],"habits":[]}';

  test('未勾选加密：原样返回明文', () {
    final out = buildBackupPayload(plain, encryptOn: false);
    expect(out, plain);
  });

  test('P0-1 守卫：勾选加密但口令为空(null/空串)必须失败，绝不降级明文', () {
    expect(
      () => buildBackupPayload(plain, encryptOn: true, pass: null),
      throwsA(isA<BackupEncryptException>()),
    );
    expect(
      () => buildBackupPayload(plain, encryptOn: true, pass: ''),
      throwsA(isA<BackupEncryptException>()),
    );
  });

  test('勾选加密且口令有效：产出信封且不含明文', () {
    final out = buildBackupPayload(plain, encryptOn: true, pass: 'Youtiao#2026');
    expect(isEncryptedEnvelope(out), isTrue);
    // 明文不得出现在落盘内容中（含任务标题与结构键）。
    expect(out.contains('买牛奶'), isFalse);
    expect(out.contains('"tasks"'), isFalse);

    // 用正确口令可还原出与原文一致的明文；错误口令必须失败。
    final back = decryptEnvelope(out, 'Youtiao#2026');
    expect(back, plain);
    expect(
      () => decryptEnvelope(out, 'wrong-password'),
      throwsA(isA<BackupDecryptException>()),
    );
  });
}
