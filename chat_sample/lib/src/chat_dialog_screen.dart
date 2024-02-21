import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_video_player_plus/cached_video_player_plus.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';
import 'package:universal_io/io.dart';

import 'package:connectycube_sdk/connectycube_sdk.dart';

import 'managers/chat_manager.dart';
import 'update_dialog_flow.dart';
import 'utils/api_utils.dart';
import 'utils/consts.dart';
import 'utils/platform_utils.dart' as platformUtils;
import 'widgets/audio_recorder.dart';
import 'widgets/audio_attachment.dart';
import 'widgets/common.dart';
import 'widgets/full_photo.dart';
import 'widgets/loading.dart';
import 'widgets/video_attachment.dart';

class ChatDialogScreen extends StatelessWidget {
  final CubeUser _cubeUser;
  final CubeDialog _cubeDialog;

  ChatDialogScreen(this._cubeUser, this._cubeDialog);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _cubeDialog.name != null ? _cubeDialog.name! : '',
        ),
        centerTitle: false,
        actions: <Widget>[
          IconButton(
            onPressed: () => showChatDetails(context, _cubeUser, _cubeDialog),
            icon: Icon(
              Icons.info_outline,
              color: Colors.white,
            ),
          ),
        ],
      ),
      body: ChatScreen(_cubeUser, _cubeDialog),
    );
  }
}

class ChatScreen extends StatefulWidget {
  static const String TAG = "_CreateChatScreenState";
  final CubeUser _cubeUser;
  final CubeDialog _cubeDialog;

  ChatScreen(this._cubeUser, this._cubeDialog);

  @override
  State createState() => ChatScreenState(_cubeUser, _cubeDialog);
}

class ChatScreenState extends State<ChatScreen> {
  final CubeUser _cubeUser;
  final CubeDialog _cubeDialog;
  final Map<int?, CubeUser?> _occupants = Map();

  late bool isLoading;
  late StreamSubscription<ConnectivityResult> connectivityStateSubscription;
  String? imageUrl;
  List<CubeMessage> listMessage = [];
  Timer? typingTimer;
  bool isTyping = false;
  String userStatus = '';
  static const int TYPING_TIMEOUT = 700;
  static const int STOP_TYPING_TIMEOUT = 2000;

  int _sendIsTypingTime = DateTime.now().millisecondsSinceEpoch;
  Timer? _sendStopTypingTimer;

  final TextEditingController textEditingController = TextEditingController();
  final ScrollController listScrollController = ScrollController();

  StreamSubscription<CubeMessage>? msgSubscription;
  StreamSubscription<MessageStatus>? deliveredSubscription;
  StreamSubscription<MessageStatus>? readSubscription;
  StreamSubscription<TypingStatus>? typingSubscription;
  StreamSubscription<MessageReaction>? reactionsSubscription;

  List<CubeMessage> _unreadMessages = [];
  List<CubeMessage> _unsentMessages = [];

  static const int messagesPerPage = 50;
  int lastPartSize = 0;

  List<CubeMessage> oldMessages = [];

  late FocusNode _editMessageFocusNode;

  bool isAudioRecording = false;

  ChatScreenState(this._cubeUser, this._cubeDialog);

  @override
  void initState() {
    super.initState();
    _initCubeChat();

    isLoading = false;
    imageUrl = '';
    listScrollController.addListener(onScrollChanged);
    connectivityStateSubscription =
        Connectivity().onConnectivityChanged.listen(onConnectivityChanged);
    _editMessageFocusNode = createEditMessageFocusNode();
  }

  @override
  void dispose() {
    msgSubscription?.cancel();
    deliveredSubscription?.cancel();
    readSubscription?.cancel();
    typingSubscription?.cancel();
    reactionsSubscription?.cancel();
    textEditingController.dispose();
    connectivityStateSubscription.cancel();
    super.dispose();
  }

  void openGallery() async {
    if (platformUtils.isVideoAttachmentsSupported) {
      showDialog(
          context: context,
          builder: (context) {
            return Dialog(
                child: Container(
                    margin: EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              pickImage();
                            },
                            child: Text('Send Image')),
                        TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              pickVideo();
                            },
                            child: Text('Send Video'))
                      ],
                    )));
          });
    } else {
      pickImage();
    }
  }

  void pickImage() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );

    if (result == null) return;

    setState(() {
      isLoading = true;
    });

    var uploadImageFuture = getUploadingMediaFuture(result);
    var imageData;

    if (kIsWeb) {
      imageData = result.files.single.bytes!;
    } else {
      imageData = File(result.files.single.path!).readAsBytesSync();
    }

    var decodedImage = await decodeImageFromList(imageData);

    uploadImageFile(uploadImageFuture, decodedImage);
  }

  void pickVideo() async {
    setState(() {
      isLoading = true;
    });

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
    );

    if (result == null) {
      setState(() {
        isLoading = false;
      });
      return;
    }

    getUploadingMediaFuture(result).then((cubeFile) {
      onSendVideoAttachment(cubeFile);
    }).catchError((onError) {
      setState(() {
        isLoading = false;
      });
      Fluttertoast.showToast(msg: 'An error occurred while sending video file');
    });
  }

  Future uploadImageFile(Future<CubeFile> uploadAction, imageData) async {
    uploadAction.then((cubeFile) {
      onSendImageAttachment(cubeFile, imageData);
    }).catchError((ex) {
      setState(() {
        isLoading = false;
      });
      Fluttertoast.showToast(msg: 'This file is not an image');
    });
  }

  void onReceiveMessage(CubeMessage message) {
    log("onReceiveMessage message= $message");
    if (message.dialogId != _cubeDialog.dialogId) return;

    addMessageToListView(message);
  }

  void onDeliveredMessage(MessageStatus status) {
    log("onDeliveredMessage message= $status");
    updateReadDeliveredStatusMessage(status, false);
  }

  void onReadMessage(MessageStatus status) {
    log("onReadMessage message= ${status.messageId}");
    updateReadDeliveredStatusMessage(status, true);
  }

  void onReactionReceived(MessageReaction reaction) {
    log("onReactionReceived message= ${reaction.messageId}");
    _updateMessageReactions(reaction);
  }

  void onTypingMessage(TypingStatus status) {
    log("TypingStatus message= ${status.userId}");
    if (status.userId == _cubeUser.id ||
        (status.dialogId != null && status.dialogId != _cubeDialog.dialogId))
      return;
    userStatus = _occupants[status.userId]?.fullName ??
        _occupants[status.userId]?.login ??
        _occupants[status.userId]?.email ??
        '';
    if (userStatus.isEmpty) return;
    userStatus = "$userStatus is typing ...";

    if (isTyping != true) {
      setState(() {
        isTyping = true;
      });
    }
    startTypingTimer();
  }

  startTypingTimer() {
    typingTimer?.cancel();
    typingTimer = Timer(Duration(milliseconds: 900), () {
      setState(() {
        isTyping = false;
      });
    });
  }

  void onSendChatMessage(String content) {
    if (content.trim() != '') {
      final message = createCubeMsg();
      message.body = content.trim();
      onSendMessage(message);
    } else {
      Fluttertoast.showToast(msg: 'Nothing to send');
    }
  }

  void onSendImageAttachment(CubeFile cubeFile, imageData) async {
    final attachment = CubeAttachment();
    attachment.id = cubeFile.uid;
    attachment.type = CubeAttachmentType.IMAGE_TYPE;
    attachment.url = cubeFile.getPublicUrl();
    attachment.height = imageData.height;
    attachment.width = imageData.width;
    final message = createCubeMsg();
    message.body = '🖼Attachment';
    message.attachments = [attachment];
    onSendMessage(message);
  }

  void onSendAudioAttachment(CubeFile cubeFile, int duration) async {
    final attachment = CubeAttachment();
    attachment.id = cubeFile.uid;
    attachment.type = CubeAttachmentType.AUDIO_TYPE;
    attachment.url = cubeFile.getPublicUrl();
    attachment.duration = duration;

    final message = createCubeMsg();
    message.body = '🎤 Attachment';
    message.attachments = [attachment];
    onSendMessage(message);
  }

  void onSendVideoAttachment(CubeFile cubeFile) async {
    var videoController = CachedVideoPlayerPlusController.networkUrl(
        Uri.parse(cubeFile.getPublicUrl()!),
        httpHeaders: {
          'Cache-Control': 'max-age=${30 * 24 * 60 * 60}',
        });

    videoController.initialize().then((_) {
      final attachment = CubeAttachment();
      attachment.id = cubeFile.uid;
      attachment.type = CubeAttachmentType.VIDEO_TYPE;
      attachment.url = cubeFile.getPublicUrl();
      attachment.width = videoController.value.size.width.toInt();
      attachment.height = videoController.value.size.height.toInt();
      attachment.duration = videoController.value.duration.inMilliseconds;

      final message = createCubeMsg();
      message.body = '🎞 Attachment';
      message.attachments = [attachment];
      onSendMessage(message);
    });
  }

  CubeMessage createCubeMsg() {
    var message = CubeMessage();
    message.dateSent = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    message.markable = true;
    message.saveToHistory = true;
    return message;
  }

  void onSendMessage(CubeMessage message) async {
    log("onSendMessage message= $message");
    textEditingController.clear();
    await _cubeDialog.sendMessage(message);
    message.senderId = _cubeUser.id;
    addMessageToListView(message);
    listScrollController.animateTo(0.0,
        duration: Duration(milliseconds: 300), curve: Curves.easeOut);
    if (_cubeDialog.type == CubeDialogType.PRIVATE) {
      ChatManager.instance.sentMessagesController
          .add(message..dialogId = _cubeDialog.dialogId);
    }
  }

  updateReadDeliveredStatusMessage(MessageStatus status, bool isRead) {
    log('[updateReadDeliveredStatusMessage]');
    setState(() {
      CubeMessage? msg = listMessage
          .firstWhereOrNull((msg) => msg.messageId == status.messageId);
      if (msg == null) return;
      if (isRead)
        msg.readIds == null
            ? msg.readIds = [status.userId]
            : msg.readIds?.add(status.userId);
      else
        msg.deliveredIds == null
            ? msg.deliveredIds = [status.userId]
            : msg.deliveredIds?.add(status.userId);

      log('[updateReadDeliveredStatusMessage] status updated for $msg');
    });
  }

  addMessageToListView(CubeMessage message) {
    setState(() {
      isLoading = false;
      int existMessageIndex = listMessage.indexWhere((cubeMessage) {
        return cubeMessage.messageId == message.messageId;
      });

      if (existMessageIndex != -1) {
        listMessage[existMessageIndex] = message;
      } else {
        listMessage.insert(0, message);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      child: SafeArea(
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                // List of messages
                buildListMessage(),
                //Typing content
                buildTyping(),
                // Input content
                buildAudioRecording(),
                buildInput(),
              ],
            ),

            // Loading
            buildLoading()
          ],
        ),
      ),
      onWillPop: onBackPress,
    );
  }

  Widget buildItem(int index, CubeMessage message) {
    markAsReadIfNeed() {
      var isOpponentMsgRead =
          message.readIds != null && message.readIds!.contains(_cubeUser.id);
      print(
          "markAsReadIfNeed message= $message, isOpponentMsgRead= $isOpponentMsgRead");
      if (message.senderId != _cubeUser.id && !isOpponentMsgRead) {
        if (message.readIds == null) {
          message.readIds = [_cubeUser.id!];
        } else {
          message.readIds!.add(_cubeUser.id!);
        }

        if (CubeChatConnection.instance.chatConnectionState ==
            CubeChatConnectionState.Ready) {
          _cubeDialog.readMessage(message);
        } else {
          _unreadMessages.add(message);
        }

        ChatManager.instance.readMessagesController.add(MessageStatus(
            _cubeUser.id!, message.messageId!, _cubeDialog.dialogId!));
      }
    }

    Widget getReadDeliveredWidget() {
      log("[getReadDeliveredWidget]");
      bool messageIsRead() {
        log("[getReadDeliveredWidget] messageIsRead");
        if (_cubeDialog.type == CubeDialogType.PRIVATE)
          return message.readIds != null &&
              (message.recipientId == null ||
                  message.readIds!.contains(message.recipientId));
        return message.readIds != null &&
            message.readIds!.any(
                (int id) => id != _cubeUser.id && _occupants.keys.contains(id));
      }

      bool messageIsDelivered() {
        log("[getReadDeliveredWidget] messageIsDelivered");
        if (_cubeDialog.type == CubeDialogType.PRIVATE)
          return message.deliveredIds != null &&
              (message.recipientId == null ||
                  message.deliveredIds!.contains(message.recipientId));
        return message.deliveredIds != null &&
            message.deliveredIds!.any(
                (int id) => id != _cubeUser.id && _occupants.keys.contains(id));
      }

      if (messageIsRead()) {
        log("[getReadDeliveredWidget] if messageIsRead");
        return getMessageStateWidget(MessageState.read);
      } else if (messageIsDelivered()) {
        log("[getReadDeliveredWidget] if messageIsDelivered");
        return getMessageStateWidget(MessageState.delivered);
      } else {
        log("[getReadDeliveredWidget] sent");
        return getMessageStateWidget(MessageState.sent);
      }
    }

    Widget getDateWidget() {
      return Text(
        DateFormat('HH:mm').format(
            DateTime.fromMillisecondsSinceEpoch(message.dateSent! * 1000)),
        style: TextStyle(
            color: greyColor, fontSize: 12.0, fontStyle: FontStyle.italic),
      );
    }

    Widget getHeaderDateWidget() {
      return Container(
        alignment: Alignment.center,
        child: Text(
          DateFormat('dd MMMM').format(
              DateTime.fromMillisecondsSinceEpoch(message.dateSent! * 1000)),
          style: TextStyle(
              color: primaryColor, fontSize: 20.0, fontStyle: FontStyle.italic),
        ),
        margin: EdgeInsets.all(10.0),
      );
    }

    bool isHeaderView() {
      int headerId = int.parse(DateFormat('ddMMyyyy').format(
          DateTime.fromMillisecondsSinceEpoch(message.dateSent! * 1000)));
      if (index >= listMessage.length - 1) {
        return false;
      }
      var msgPrev = listMessage[index + 1];
      int nextItemHeaderId = int.parse(DateFormat('ddMMyyyy').format(
          DateTime.fromMillisecondsSinceEpoch(msgPrev.dateSent! * 1000)));
      var result = headerId != nextItemHeaderId;
      return result;
    }

    if (message.senderId == _cubeUser.id) {
      // Right (own message)
      return Column(
        children: <Widget>[
          isHeaderView() ? getHeaderDateWidget() : SizedBox.shrink(),
          GestureDetector(
            onLongPress: () => _reactOnMessage(message),
            child: Row(
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.only(
                      bottom: isLastMessageRight(index) ? 20.0 : 10.0,
                      right: 4.0),
                  child: GestureDetector(
                    onTap: () => _reactOnMessage(message),
                    child: Icon(Icons.add_reaction_outlined,
                        size: 16, color: Colors.grey),
                  ),
                ),
                message.attachments?.isNotEmpty ?? false
                    // Image
                    ? Container(
                        decoration: BoxDecoration(
                            color: greyColor2,
                            borderRadius: BorderRadius.circular(8.0)),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _buildAttachmentWidget(message),
                              if (message.reactions != null &&
                                  message.reactions!.total.isNotEmpty)
                                getReactionsWidget(message),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  getDateWidget(),
                                  getReadDeliveredWidget(),
                                ],
                              ),
                            ]),
                        margin: EdgeInsets.only(
                            bottom: isLastMessageRight(index) ? 20.0 : 10.0,
                            right: 10.0),
                        padding: EdgeInsets.fromLTRB(4.0, 4.0, 4.0, 4.0),
                      )
                    : message.body != null && message.body!.isNotEmpty
                        // Text
                        ? Flexible(
                            child: Container(
                              constraints: BoxConstraints(maxWidth: 480),
                              padding: EdgeInsets.fromLTRB(8.0, 4.0, 8.0, 4.0),
                              decoration: BoxDecoration(
                                  color: greyColor2,
                                  borderRadius: BorderRadius.circular(8.0)),
                              margin: EdgeInsets.only(
                                  bottom:
                                      isLastMessageRight(index) ? 20.0 : 10.0,
                                  right: 10.0),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      message.body!,
                                      style: TextStyle(color: primaryColor),
                                    ),
                                    if (message.reactions != null &&
                                        message.reactions!.total.isNotEmpty)
                                      getReactionsWidget(message),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        getDateWidget(),
                                        getReadDeliveredWidget(),
                                      ],
                                    ),
                                  ]),
                            ),
                          )
                        : Container(
                            child: Text(
                              "Empty",
                              style: TextStyle(color: primaryColor),
                            ),
                            padding:
                                EdgeInsets.fromLTRB(15.0, 10.0, 15.0, 10.0),
                            width: 200.0,
                            decoration: BoxDecoration(
                                color: greyColor2,
                                borderRadius: BorderRadius.circular(8.0)),
                            margin: EdgeInsets.only(
                                bottom: isLastMessageRight(index) ? 20.0 : 10.0,
                                right: 10.0),
                          ),
              ],
              mainAxisAlignment: MainAxisAlignment.end,
            ),
          ),
        ],
      );
    } else {
      // Left (opponent message)
      markAsReadIfNeed();
      return Container(
        child: Column(
          children: <Widget>[
            isHeaderView() ? getHeaderDateWidget() : SizedBox.shrink(),
            GestureDetector(
              onLongPress: () => _reactOnMessage(message),
              child: Row(
                children: <Widget>[
                  getUserAvatarWidget(_occupants[message.senderId], 30),
                  message.attachments?.isNotEmpty ?? false
                      ? Container(
                          decoration: BoxDecoration(
                              color: primaryColor,
                              borderRadius: BorderRadius.circular(8.0)),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildAttachmentWidget(message),
                                if (message.reactions != null &&
                                    message.reactions!.total.isNotEmpty)
                                  getReactionsWidget(message),
                                getDateWidget(),
                              ]),
                          margin: EdgeInsets.only(left: 10.0),
                          padding: EdgeInsets.fromLTRB(4.0, 4.0, 4.0, 4.0),
                        )
                      : message.body != null && message.body!.isNotEmpty
                          ? Flexible(
                              child: Container(
                                constraints: BoxConstraints(
                                    minWidth: 0.0, maxWidth: 480),
                                padding:
                                    EdgeInsets.fromLTRB(8.0, 4.0, 8.0, 4.0),
                                decoration: BoxDecoration(
                                    color: primaryColor,
                                    borderRadius: BorderRadius.circular(8.0)),
                                margin: EdgeInsets.only(left: 10.0),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        message.body!,
                                        style: TextStyle(color: Colors.white),
                                      ),
                                      if (message.reactions != null &&
                                          message.reactions!.total.isNotEmpty)
                                        getReactionsWidget(message),
                                      getDateWidget(),
                                    ]),
                              ),
                            )
                          : Container(
                              child: Text(
                                "Empty",
                                style: TextStyle(color: primaryColor),
                              ),
                              padding:
                                  EdgeInsets.fromLTRB(15.0, 10.0, 15.0, 10.0),
                              width: 200.0,
                              decoration: BoxDecoration(
                                  color: greyColor2,
                                  borderRadius: BorderRadius.circular(8.0)),
                              margin: EdgeInsets.only(
                                  bottom:
                                      isLastMessageRight(index) ? 20.0 : 10.0,
                                  right: 10.0),
                            ),
                  Padding(
                    padding: EdgeInsets.only(
                        // bottom: isLastMessageRight(index) ? 20.0 : 10.0,
                        left: 4.0),
                    child: GestureDetector(
                      onTap: () => _reactOnMessage(message),
                      child: Icon(Icons.add_reaction_outlined,
                          size: 16, color: primaryColor),
                    ),
                  ),
                ],
              ),
            )
          ],
          crossAxisAlignment: CrossAxisAlignment.start,
        ),
        margin: EdgeInsets.only(bottom: 10.0),
      );
    }
  }

  bool isLastMessageLeft(int index) {
    if ((index > 0 && listMessage[index - 1].id == _cubeUser.id) ||
        index == 0) {
      return true;
    } else {
      return false;
    }
  }

  bool isLastMessageRight(int index) {
    if ((index > 0 && listMessage[index - 1].id != _cubeUser.id) ||
        index == 0) {
      return true;
    } else {
      return false;
    }
  }

  Widget buildLoading() {
    return Positioned(
      child: isLoading ? const Loading() : Container(),
    );
  }

  Widget buildTyping() {
    return Visibility(
      visible: isTyping,
      child: Container(
        child: Text(
          userStatus,
          style: TextStyle(color: primaryColor),
        ),
        alignment: Alignment.centerLeft,
        margin: EdgeInsets.all(16.0),
      ),
    );
  }

  Widget buildAudioRecording() {
    return Visibility(
      visible: isAudioRecording,
      child: AudioRecorder(
        onAccept: sendAudioAttachment,
        onClose: () {
          setState(() {
            isAudioRecording = false;
          });
        },
      ),
    );
  }

  Widget buildInput() {
    return Container(
      child: Row(
        children: <Widget>[
          // Button send image
          Material(
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: 1.0),
              child: IconButton(
                icon: Icon(Icons.attach_file_rounded),
                onPressed: () {
                  openGallery();
                },
                color: primaryColor,
              ),
            ),
            color: Colors.white,
          ),

          // Edit text
          Flexible(
            child: Container(
              child: TextField(
                autofocus: platformUtils.isDesktop(),
                focusNode: _editMessageFocusNode,
                keyboardType: TextInputType.multiline,
                maxLines: null,
                style: TextStyle(color: primaryColor, fontSize: 15.0),
                controller: textEditingController,
                decoration: InputDecoration.collapsed(
                  hintText: 'Type your message...',
                  hintStyle: TextStyle(color: greyColor),
                ),
                onChanged: (text) {
                  sendIsTypingStatus();
                },
              ),
            ),
          ),

          // Button send message
          Material(
            child: Container(
              margin: EdgeInsets.only(left: 4, right: 2.0),
              child: IconButton(
                icon: Icon(Icons.send),
                onPressed: () => onSendChatMessage(textEditingController.text),
                color: primaryColor,
              ),
            ),
            color: Colors.white,
          ),
          // Button record audio
          IconButton(
            splashRadius: 12,
            icon: Icon(Icons.mic_none_rounded),
            onPressed: () {
              if (!isAudioRecording) {
                setState(() {
                  isAudioRecording = true;
                });
              }
            },
            color: isAudioRecording ? Colors.grey : primaryColor,
          ),
        ],
      ),
      width: double.infinity,
      height: 50.0,
      decoration: BoxDecoration(
          border: Border(top: BorderSide(color: greyColor2, width: 0.5)),
          color: Colors.white),
    );
  }

  Widget buildListMessage() {
    getWidgetMessages(listMessage) {
      return ListView.builder(
        padding: EdgeInsets.all(10.0),
        itemBuilder: (context, index) => buildItem(index, listMessage[index]),
        itemCount: listMessage.length,
        reverse: true,
        controller: listScrollController,
      );
    }

    return Flexible(
      child: StreamBuilder<List<CubeMessage>>(
        stream: getMessagesList().asStream(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(
                child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(themeColor)));
          } else {
            listMessage = snapshot.data ?? [];
            return getWidgetMessages(listMessage);
          }
        },
      ),
    );
  }

  Future<List<CubeMessage>> getMessagesList() async {
    if (listMessage.isNotEmpty) return Future.value(listMessage);

    Completer<List<CubeMessage>> completer = Completer();
    List<CubeMessage>? messages;
    try {
      await Future.wait<void>([
        getMessagesByDate(0, false).then((loadedMessages) {
          isLoading = false;
          messages = loadedMessages;
        }),
        getAllUsersByIds(_cubeDialog.occupantsIds!.toSet()).then((result) =>
            _occupants.addAll(Map.fromIterable(result!.items,
                key: (item) => item.id, value: (item) => item)))
      ]);
      completer.complete(messages);
    } catch (error) {
      completer.completeError(error);
    }
    return completer.future;
  }

  void onScrollChanged() {
    if ((listScrollController.position.pixels ==
            listScrollController.position.maxScrollExtent) &&
        messagesPerPage >= lastPartSize) {
      setState(() {
        isLoading = true;

        if (oldMessages.isNotEmpty) {
          getMessagesBetweenDates(
                  oldMessages.first.dateSent ?? 0,
                  listMessage.last.dateSent ??
                      DateTime.now().millisecondsSinceEpoch ~/ 1000)
              .then((newMessages) {
            setState(() {
              isLoading = false;

              listMessage.addAll(newMessages);

              if (newMessages.length < messagesPerPage) {
                oldMessages.insertAll(0, listMessage);
                listMessage = List.from(oldMessages);
                oldMessages.clear();
              }
            });
          });
        } else {
          getMessagesByDate(listMessage.last.dateSent ?? 0, false)
              .then((messages) {
            setState(() {
              isLoading = false;
              listMessage.addAll(messages);
            });
          });
        }
      });
    }
  }

  Future<bool> onBackPress() {
    return Navigator.pushNamedAndRemoveUntil<bool>(
        context, 'select_dialog', (r) => false,
        arguments: {USER_ARG_NAME: _cubeUser}).then((value) {
      return true;
    });
  }

  _initChatListeners() {
    log("[_initChatListeners]");
    msgSubscription = CubeChatConnection
        .instance.chatMessagesManager!.chatMessagesStream
        .listen(onReceiveMessage);
    deliveredSubscription = CubeChatConnection
        .instance.messagesStatusesManager!.deliveredStream
        .listen(onDeliveredMessage);
    readSubscription = CubeChatConnection
        .instance.messagesStatusesManager!.readStream
        .listen(onReadMessage);
    typingSubscription = CubeChatConnection
        .instance.typingStatusesManager!.isTypingStream
        .listen(onTypingMessage);
    reactionsSubscription = CubeChatConnection
        .instance.messagesReactionsManager?.reactionsStream
        .listen(onReactionReceived);
  }

  void _initCubeChat() {
    log("_initCubeChat");
    if (CubeChatConnection.instance.isAuthenticated()) {
      log("[_initCubeChat] isAuthenticated");
      _initChatListeners();
    } else {
      log("[_initCubeChat] not authenticated");
      CubeChatConnection.instance.connectionStateStream.listen((state) {
        log("[_initCubeChat] state $state");
        if (CubeChatConnectionState.Ready == state) {
          _initChatListeners();

          if (_unreadMessages.isNotEmpty) {
            _unreadMessages.forEach((cubeMessage) {
              _cubeDialog.readMessage(cubeMessage);
            });
            _unreadMessages.clear();
          }

          if (_unsentMessages.isNotEmpty) {
            _unsentMessages.forEach((cubeMessage) {
              _cubeDialog.sendMessage(cubeMessage);
            });

            _unsentMessages.clear();
          }
        }
      });
    }
  }

  void sendIsTypingStatus() {
    var currentTime = DateTime.now().millisecondsSinceEpoch;
    var isTypingTimeout = currentTime - _sendIsTypingTime;
    if (isTypingTimeout >= TYPING_TIMEOUT) {
      _sendIsTypingTime = currentTime;
      _cubeDialog.sendIsTypingStatus();
      _startStopTypingStatus();
    }
  }

  void _startStopTypingStatus() {
    _sendStopTypingTimer?.cancel();
    _sendStopTypingTimer =
        Timer(Duration(milliseconds: STOP_TYPING_TIMEOUT), () {
      _cubeDialog.sendStopTypingStatus();
    });
  }

  Future<List<CubeMessage>> getMessagesByDate(int date, bool isLoadNew) async {
    var params = GetMessagesParameters();
    params.sorter = RequestSorter(SORT_DESC, '', 'date_sent');
    params.limit = messagesPerPage;
    params.filters = [
      RequestFilter('', 'date_sent', isLoadNew || date == 0 ? 'gt' : 'lt', date)
    ];

    return getMessages(_cubeDialog.dialogId!, params.getRequestParameters())
        .then((result) {
          lastPartSize = result!.items.length;

          return result.items;
        })
        .whenComplete(() {})
        .catchError((onError) {
          return List<CubeMessage>.empty(growable: true);
        });
  }

  Future<List<CubeMessage>> getMessagesBetweenDates(
      int startDate, int endDate) async {
    var params = GetMessagesParameters();
    params.sorter = RequestSorter(SORT_DESC, '', 'date_sent');
    params.limit = messagesPerPage;
    params.filters = [
      RequestFilter('', 'date_sent', 'gt', startDate),
      RequestFilter('', 'date_sent', 'lt', endDate)
    ];

    return getMessages(_cubeDialog.dialogId!, params.getRequestParameters())
        .then((result) {
      return result!.items;
    });
  }

  void onConnectivityChanged(ConnectivityResult connectivityType) {
    log("[ChatScreenState] connectivityType changed to '$connectivityType'");

    if (connectivityType == ConnectivityResult.wifi ||
        connectivityType == ConnectivityResult.mobile) {
      setState(() {
        isLoading = true;
      });

      getMessagesBetweenDates(listMessage.first.dateSent ?? 0,
              DateTime.now().millisecondsSinceEpoch ~/ 1000)
          .then((newMessages) {
        setState(() {
          if (newMessages.length == messagesPerPage) {
            oldMessages = List.from(listMessage);
            listMessage = newMessages;
          } else {
            listMessage.insertAll(0, newMessages);
          }
        });
      }).whenComplete(() {
        setState(() {
          isLoading = false;
        });
      });
    }
  }

  getReactionsWidget(CubeMessage message) {
    if (message.reactions == null) return Container();

    var isOwnMessage = message.senderId == _cubeUser.id;

    return LayoutBuilder(builder: (context, constraints) {
      var widgetWidth =
          constraints.maxWidth == double.infinity ? 240 : constraints.maxWidth;
      var maxColumns = (widgetWidth / 60).round();
      if (message.reactions!.total.length < maxColumns) {
        maxColumns = message.reactions!.total.length;
      }

      return SizedBox(
          width: maxColumns * 56,
          child: GridView.count(
            primary: false,
            crossAxisCount: maxColumns,
            mainAxisSpacing: 4,
            childAspectRatio: 2,
            physics: NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 2),
            children: <Widget>[
              ...message.reactions!.total.keys.map((reaction) {
                return GestureDetector(
                    onTap: () => _performReaction(Emoji(reaction, ''), message),
                    child: Padding(
                        padding: EdgeInsets.only(
                          left: isOwnMessage ? 4 : 0,
                          right: isOwnMessage ? 0 : 4,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.all(
                            Radius.circular(16),
                          ),
                          child: Container(
                              padding: EdgeInsets.symmetric(
                                  vertical: 4, horizontal: 6),
                              color: message.reactions!.own.contains(reaction)
                                  ? Colors.green
                                  : Colors.grey,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  Text(reaction,
                                      style: kIsWeb
                                          ? TextStyle(
                                              color: Colors.green,
                                              fontFamily: 'NotoColorEmoji')
                                          : null),
                                  Text(
                                      ' ${message.reactions!.total[reaction].toString()}',
                                      style: TextStyle(
                                        color: Colors.white,
                                      )),
                                ],
                              )),
                        )));
              }).toList()
            ],
          ));
    });
  }

  _reactOnMessage(CubeMessage message) {
    showDialog<Emoji>(
        context: context,
        builder: (BuildContext context) {
          return Dialog(
              child: Container(
                  margin: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8.0)),
                  width: 400,
                  height: 400,
                  child: EmojiPicker(
                    config: Config(
                      emojiTextStyle: kIsWeb
                          ? TextStyle(
                              color: Colors.green, fontFamily: 'NotoColorEmoji')
                          : null,
                      iconColorSelected: Colors.green,
                      indicatorColor: Colors.green,
                      bgColor: Colors.white,
                    ),
                    onEmojiSelected: (category, emoji) {
                      Navigator.pop(context, emoji);
                    },
                  )));
        }).then((emoji) {
      log("onEmojiSelected emoji: ${emoji?.emoji}");
      if (emoji != null) {
        _performReaction(emoji, message);
      }
    });
  }

  void _performReaction(Emoji emoji, CubeMessage message) {
    if ((message.reactions?.own.isNotEmpty ?? false) &&
        (message.reactions?.own.contains(emoji.emoji) ?? false)) {
      removeMessageReaction(message.messageId!, emoji.emoji);
      _updateMessageReactions(MessageReaction(
          _cubeUser.id!, _cubeDialog.dialogId!, message.messageId!,
          removeReaction: emoji.emoji));
    } else {
      addMessageReaction(message.messageId!, emoji.emoji);
      _updateMessageReactions(MessageReaction(
          _cubeUser.id!, _cubeDialog.dialogId!, message.messageId!,
          addReaction: emoji.emoji));
    }
  }

  void _updateMessageReactions(MessageReaction reaction) {
    log('[_updateMessageReactions]');
    setState(() {
      CubeMessage? msg = listMessage
          .firstWhereOrNull((msg) => msg.messageId == reaction.messageId);
      if (msg == null) return;

      if (msg.reactions == null) {
        msg.reactions = CubeMessageReactions.fromJson({
          'own': {if (reaction.userId == _cubeUser.id) reaction.addReaction},
          'total': {reaction.addReaction: 1}
        });
      } else {
        if (reaction.addReaction != null) {
          if (reaction.userId != _cubeUser.id ||
              !(msg.reactions?.own.contains(reaction.addReaction) ?? false)) {
            if (reaction.userId == _cubeUser.id) {
              msg.reactions!.own.add(reaction.addReaction!);
            }

            msg.reactions!.total[reaction.addReaction!] =
                msg.reactions!.total[reaction.addReaction] == null
                    ? 1
                    : msg.reactions!.total[reaction.addReaction]! + 1;
          }
        }

        if (reaction.removeReaction != null) {
          if (reaction.userId != _cubeUser.id ||
              (msg.reactions?.own.contains(reaction.removeReaction) ?? false)) {
            if (reaction.userId == _cubeUser.id) {
              msg.reactions!.own.remove(reaction.removeReaction!);
            }

            msg.reactions!.total[reaction.removeReaction!] =
                msg.reactions!.total[reaction.removeReaction] != null &&
                        msg.reactions!.total[reaction.removeReaction]! > 0
                    ? msg.reactions!.total[reaction.removeReaction]! - 1
                    : 0;
          }

          msg.reactions!.total.removeWhere((key, value) => value == 0);
        }
      }
    });
  }

  FocusNode createEditMessageFocusNode() {
    return FocusNode(
      onKey: (FocusNode node, RawKeyEvent evt) {
        if (!evt.isShiftPressed && evt.logicalKey == LogicalKeyboardKey.enter) {
          if (evt is RawKeyDownEvent) {
            onSendChatMessage(textEditingController.text);
          }
          _editMessageFocusNode.requestFocus();
          return KeyEventResult.handled;
        } else if (evt.logicalKey == LogicalKeyboardKey.enter) {
          if (evt is RawKeyDownEvent) {
            setState(() {
              textEditingController.text = textEditingController.text + '\n';
              textEditingController.selection = TextSelection.collapsed(
                  offset: textEditingController.text.length);
            });
          }
          _editMessageFocusNode.requestFocus();
          return KeyEventResult.handled;
        } else {
          return KeyEventResult.ignored;
        }
      },
    );
  }

  Widget _buildAttachmentWidget(CubeMessage message) {
    var attachmentType = message.attachments?.firstOrNull?.type ?? 'unknown';

    switch (attachmentType) {
      case CubeAttachmentType.IMAGE_TYPE:
        return _buildImageAttachmentWidget(message);
      case CubeAttachmentType.AUDIO_TYPE:
        return _buildAudioAttachmentWidget(message);
      case CubeAttachmentType.VIDEO_TYPE:
        return _buildVideoAttachmentWidget(message);
      case CubeAttachmentType.LOCATION_TYPE:
      default:
        return SizedBox.shrink();
    }
  }

  Widget _buildImageAttachmentWidget(CubeMessage message) {
    return Container(
      padding: EdgeInsets.only(bottom: 2.0),
      child: GestureDetector(
        onTap: () {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (context) =>
                      FullPhoto(url: message.attachments!.first.url!)));
        },
        child: ClipRRect(
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(8.0), bottom: Radius.circular(2.0)),
          // topLeft: Radius.circular(8.0), topRight: Radius.circular(8.0)),
          child: CachedNetworkImage(
            placeholder: (context, url) => Container(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(themeColor),
              ),
              width: 200.0,
              height: 200.0,
              padding: EdgeInsets.all(70.0),
              decoration: BoxDecoration(
                color: greyColor2,
                borderRadius: BorderRadius.all(
                  Radius.circular(8.0),
                ),
              ),
            ),
            errorWidget: (context, url, error) => Material(
              child: Image.asset(
                'images/img_not_available.jpeg',
                width: 200.0,
                height: 200.0,
                fit: BoxFit.cover,
              ),
              borderRadius: BorderRadius.all(
                Radius.circular(8.0),
              ),
              clipBehavior: Clip.hardEdge,
            ),
            imageUrl: message.attachments!.first.url!,
            width: 200.0,
            height: 200.0,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  Widget _buildAudioAttachmentWidget(CubeMessage message) {
    var attachment = message.attachments?.firstOrNull;
    if (attachment == null) return SizedBox.shrink();

    return AudioAttachment(
        key: Key(message.messageId!),
        accentColor: Colors.green,
        source: attachment.url ?? '',
        duration: attachment.duration ?? 0);
  }

  Widget _buildVideoAttachmentWidget(CubeMessage message) {
    var attachment = message.attachments?.firstOrNull;
    if (attachment == null) return SizedBox.shrink();

    return platformUtils.isVideoAttachmentsSupported
        ? VideoAttachment(
            key: Key(message.messageId!),
            accentColor: Colors.green,
            source: attachment.url ?? '',
            videoSize: Size((attachment.width ?? 300).toDouble(),
                (attachment.height ?? 200).toDouble()),
          )
        : VideoAttachmentStub(
            source: attachment.url ?? '',
            videoSize: Size((attachment.width ?? 300).toDouble(),
                (attachment.height ?? 200).toDouble()),
            accentColor: Colors.green,
          );
  }

  void sendAudioAttachment(
      String audioFilePath, String mimeType, String fileName, int duration) {
    log('[sendAudioAttachment] audioFilePath: $audioFilePath, mimeType: $mimeType, fileName: $fileName, duration: $duration');

    setState(() {
      isLoading = true;
      isAudioRecording = false;
    });

    getUploadingFileFuture(audioFilePath, mimeType, fileName, isPublic: true)
        .then((cubeFile) {
      onSendAudioAttachment(cubeFile, duration);
    }).catchError((onError) {
      log('[sendAudioAttachment] onError: $onError');
      setState(() {
        isLoading = false;
      });
      Fluttertoast.showToast(
          msg: 'An error occurred while sending voice message');
    });
  }
}

void showChatDetails(
    BuildContext context, CubeUser cubeUser, CubeDialog cubeDialog) async {
  log("_chatDetails= $cubeDialog");

  platformUtils.showModal(
      context: context, child: UpdateDialog(cubeUser, cubeDialog));
}
