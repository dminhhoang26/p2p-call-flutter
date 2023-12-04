import 'package:flutter/material.dart';

import 'package:connectycube_sdk/connectycube_sdk.dart';

class MinorVideo extends StatelessWidget {
  final double width;
  final double height;
  final RTCVideoRenderer renderer;
  final RTCVideoViewObjectFit objectFit;
  final bool mirror;
  final String? name;
  final Function()? onTap;
  final Function(DragUpdateDetails details)? onPanUpdate;
  final Function(DragEndDetails details)? onPanEnd;

  MinorVideo({
    super.key,
    required this.width,
    required this.height,
    required this.renderer,
    required this.mirror,
    this.name,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    this.onTap,
    this.onPanUpdate,
    this.onPanEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: onPanUpdate,
      onPanEnd: onPanEnd,
      onTap: onTap,
      child: AbsorbPointer(
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12.0),
                child: RTCVideoView(
                  renderer,
                  objectFit: objectFit,
                  mirror: mirror,
                ),
              ),
              Visibility(
                visible: name != null && name!.isNotEmpty,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    margin: EdgeInsets.only(bottom: 8),
                    child: Text(
                      name ?? 'Unknown',
                      style: TextStyle(
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Colors.black,
                            offset: Offset(2, 1),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
