import 'package:material_ui/material_ui.dart';

import '../player_model.dart';

/// 音量按钮。点开是一个带滑块的弹出面板 —— 宽屏窄屏行为一致，
/// 不做「窄屏就只剩静音开关」那种缩水处理。
class VolumeButton extends StatelessWidget {
  const VolumeButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: playerModel,
      builder: (context, _) {
        final volume = playerModel.volume;
        // 图标分四档。不用 switch 是因为要比较 double 大小，
        // 关系模式匹配 double 容易在 0 和 0.0 上翻车。
        final IconData icon;
        if (volume <= 0.001) {
          icon = Icons.volume_off;
        } else if (volume < 0.34) {
          icon = Icons.volume_mute;
        } else if (volume < 0.67) {
          icon = Icons.volume_down;
        } else {
          icon = Icons.volume_up;
        }

        return MenuAnchor(
          // 面板从按钮左上方展开，避免贴着屏幕底边时被裁掉
          alignmentOffset: const Offset(-80, -56),
          menuChildren: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 12, 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    onPressed: playerModel.toggleMute,
                    icon: Icon(icon, size: 20),
                    visualDensity: VisualDensity.compact,
                    tooltip: playerModel.muted ? '取消静音' : '静音',
                  ),
                  SizedBox(
                    width: 168,
                    child: Slider(
                      value: volume,
                      onChanged: playerModel.setVolume,
                    ),
                  ),
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${(volume * 100).round()}',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
          builder: (context, controller, child) {
            return IconButton(
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: Icon(icon),
              tooltip: '音量',
            );
          },
        );
      },
    );
  }
}
