#!/usr/bin/env python3
"""Turbo IO / Codex  ->  Hermes 客户端重命名层（云端构建前应用）

背景：作者的 iOS 独立客户端（apps/RayNeoCompanion）是按 Codex 当后端写的，
我们这台机器上的后端是 Hermes。作者那套只当参考，不照搬：
  - 构建前把会编进 App 的源码里，标识符与用户可见文案统一改名
  - 作者仓库保持可对齐上游，改名只发生在本层（每次构建都从上游语义长出来）
  - 改名后若仍残留 Codex/codex，直接让构建失败（fail closed，不装作成功）
"""

import pathlib
import sys

# 会编进 App 的源码目录（= 改名范围）
TARGETS = [
    pathlib.Path('apps/RayNeoCompanion/Sources'),   # 主源码
    pathlib.Path('apps/RayNeoCompanion/Tests'),     # 测试里的类型引用
]
# 被 App target 依赖的零散源文件
FILES = [
    pathlib.Path('core-probe/Sources/CloudVoicePipeline.swift'),
]

# 全局改名：标识符与文案一起走，避免半改导致编译不过
GLOBAL = [('Codex', 'Hermes'), ('codex', 'hermes')]

# 全局改名之后读起来别扭的中文，逐条修顺
FIXUPS = [
    ('已交给Hermes', '已交给 Hermes'),
    ('Codex 工具未开启。', 'Hermes 工具未开启。'),
    ('Hermes 进程离线', 'Hermes 侧离线'),
    ('还没有收到 Hermes 输出', '还没有收到 Hermes 的回复'),
    ('尚未取得当前Hermes任务状态，请在Turbo IOHermes页连接并选择任务。',
     '尚未取得当前 Hermes 任务状态，请在 Turbo IO 的 Hermes 页连接并选择任务。'),
    ('请在Turbo IOHermes页连接', '请在 Turbo IO 的 Hermes 页连接'),
    ('这是Turbo IO连接测试。不要读写文件或运行工具，只回复：Turbo IOHermes校验 ',
     '这是 Turbo IO x Hermes 连接测试。不要读写文件或运行工具，只回复：Hermes 校验 '),
    ('允许 DeepSeek 调用 Hermes 工具', '允许语音把任务交给 Hermes'),
    ('调用提供的Hermes工具', '调用提供的 Hermes 工具'),
    ('不等于停止Hermes', '不等于停止 Hermes'),
    ('Hermes未配置，未执行。', 'Hermes 未配置，未执行。'),
    ('Hermes工具提交', 'Hermes 工具提交'),
]

LEFT = ('Codex', 'codex')


def sources():
    found = []
    for d in TARGETS:
        if d.is_dir():
            found.extend(sorted(d.glob('*.swift')))
    for f in FILES:
        if f.is_file():
            found.append(f)
    return found


def main() -> int:
    paths = sources()
    if not paths:
        print('FAIL: no source files matched', file=sys.stderr)
        return 1

    changed = 0
    for path in paths:
        text = path.read_text(encoding='utf-8')
        original = text
        for old, new in GLOBAL:
            text = text.replace(old, new)
        for old, new in FIXUPS:
            text = text.replace(old, new)
        if text != original:
            path.write_text(text, encoding='utf-8')
            changed += 1
            print(f'  patched {path}')

    print(f'rebrand: {changed} file(s) changed out of {len(paths)} scanned')

    leftovers = []
    for path in paths:
        text = path.read_text(encoding='utf-8')
        for token in LEFT:
            if token in text:
                leftovers.append(f'{path}:{token}')
    if leftovers:
        print('FAIL: leftover Codex naming -> ' + ', '.join(sorted(set(leftovers))), file=sys.stderr)
        return 1
    print('rebrand: no Codex/codex naming left in app sources; handing over to xcodebuild')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
