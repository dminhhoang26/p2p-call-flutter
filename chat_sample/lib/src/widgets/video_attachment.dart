import 'package:cached_video_player_plus/cached_video_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import 'full_video.dart';

class VideoAttachment extends StatefulWidget {
  final Size videoSize;
  final String source;
  final Color accentColor;

  const VideoAttachment({
    Key? key,
    required this.source,
    this.accentColor = Colors.blue,
    required this.videoSize,
  }) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return VideoAttachmentState();
  }
}

class VideoAttachmentState extends State<VideoAttachment> {
  final String TAG = 'VideoAttachment';

  late CachedVideoPlayerPlusController controller;

  @override
  void initState() {
    super.initState();
    controller = CachedVideoPlayerPlusController.networkUrl(
        Uri.parse(widget.source),
        httpHeaders: {
          'Cache-Control': 'max-age=${30 * 24 * 60 * 60}',
        });
    controller.addListener(() {
      if (mounted) {
        setState(() {
          if (controller.value.duration != Duration.zero &&
              controller.value.position == controller.value.duration) {
            controller.seekTo(Duration.zero).then((value) {
              controller.pause();
            });
          }
        });
      }
    });
    controller.initialize();
  }

  @override
  Widget build(BuildContext context) {
    var aspectRatio = widget.videoSize.width / widget.videoSize.height;

    bool isVerticalVideo() {
      return aspectRatio < 1;
    }

    var widgetWidth;
    var widgetHeight;

    controller.addListener(() {});

    if (isVerticalVideo()) {
      widgetHeight = 300;
      widgetWidth = widgetHeight * aspectRatio;
    } else {
      widgetWidth = 300;
      widgetHeight = widgetWidth ~/ aspectRatio;
    }

    return Container(
      width: widgetWidth.toDouble(),
      height: widgetHeight.toDouble(),
      child: GestureDetector(
        onTap: () {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (context) => FullVideoScreen(
                        url: widget.source,
                        controller: kIsWeb ? null : controller,
                      )));
        },
        child: ClipRRect(
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(8.0), bottom: Radius.circular(2.0)),
          // topLeft: Radius.circular(8.0), topRight: Radius.circular(8.0)),
          child: Stack(children: [
            AbsorbPointer(
              child: CachedVideoPlayerPlus(controller, key: widget.key),
            ),
            Center(
              child: Visibility(
                visible: controller.value.isBuffering,
                child: Container(
                  width: 42,
                  height: 42,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                ),
              ),
            ),
            Center(
              child: FloatingActionButton(
                heroTag: 'PlayPauseVideo_${widget.source.split('/').last}',
                onPressed: playPause,
                child: Icon(controller.value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
                backgroundColor: Colors.black38,
                elevation: 0.0,
                mini: true,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void playPause() {
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }
}

class VideoAttachmentStub extends StatelessWidget {
  final Size videoSize;
  final String source;
  final Color accentColor;

  const VideoAttachmentStub({
    Key? key,
    required this.source,
    this.accentColor = Colors.blue,
    required this.videoSize,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var defaultStyle = TextStyle(
      color: Colors.grey,
      fontSize: 14.0,
    );
    var linkStyle = TextStyle(color: accentColor);

    var aspectRatio = videoSize.width / videoSize.height;

    bool isVerticalVideo() {
      return aspectRatio < 1;
    }

    var widgetWidth;
    var widgetHeight;

    if (isVerticalVideo()) {
      widgetHeight = 300;
      widgetWidth = widgetHeight * aspectRatio;
    } else {
      widgetWidth = 300;
      widgetHeight = widgetWidth ~/ aspectRatio;
    }

    return Container(
      width: widgetWidth.toDouble(),
      height: widgetHeight.toDouble(),
      margin: EdgeInsets.all(8),
      child: Center(
        child: RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: defaultStyle,
            children: <TextSpan>[
              TextSpan(
                  text:
                      'This attachment\'s type is temporarily unsupported on the current platform. Click the '),
              TextSpan(
                  text: 'link ',
                  style: linkStyle,
                  recognizer: TapGestureRecognizer()
                    ..onTap = () {
                      launchUrl(Uri.parse(source));
                    }),
              TextSpan(text: 'to open it in your browser.'),
            ],
          ),
        ),
      ),
    );
  }
}
