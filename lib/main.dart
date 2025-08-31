import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Institute Chat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const RoomListScreen(),
    );
  }
}

class RoomListScreen extends StatefulWidget {
  const RoomListScreen({super.key});
  @override
  State<RoomListScreen> createState() => _RoomListScreenState();
}

class _RoomListScreenState extends State<RoomListScreen> {
  final TextEditingController _roomCtrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rooms')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _roomCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Create or join room (e.g. Class-10A)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final name = _roomCtrl.text.trim();
                    if (name.isNotEmpty) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(roomId: name),
                        ),
                      );
                    }
                  },
                  child: const Text('Go'),
                )
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('rooms')
                  .orderBy('lastActivity', descending: true)
                  .limit(50)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Text('No rooms yet. Create one above.'),
                  );
                }
                return ListView.separated(
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final r = docs[i].data();
                    final id = docs[i].id;
                    final last = r['lastMessage'] ?? '';
                    return ListTile(
                      title: Text(id),
                      subtitle: Text(last, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatScreen(roomId: id),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final String roomId;
  const ChatScreen({super.key, required this.roomId});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _msgCtrl = TextEditingController();
  final _uuid = const Uuid();
  bool _sending = false;

  CollectionReference<Map<String, dynamic>> get _roomRef =>
      FirebaseFirestore.instance.collection('rooms').doc(widget.roomId).collection('messages');

  Future<void> _ensureRoom() async {
    final roomDoc = FirebaseFirestore.instance.collection('rooms').doc(widget.roomId);
    final snap = await roomDoc.get();
    if (!snap.exists) {
      await roomDoc.set({
        'createdAt': FieldValue.serverTimestamp(),
        'lastActivity': FieldValue.serverTimestamp(),
        'lastMessage': '',
      });
    }
  }

  Future<void> _sendText() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await _ensureRoom();
      await _roomRef.add({
        'text': text,
        'senderId': FirebaseAuth.instance.currentUser!.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'attachmentUrl': null,
        'attachmentName': null,
        'attachmentType': null,
      });
      await FirebaseFirestore.instance.collection('rooms').doc(widget.roomId).update({
        'lastActivity': FieldValue.serverTimestamp(),
        'lastMessage': text,
      });
      _msgCtrl.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (x == null) return;
    await _uploadAndSend(File(x.path), originalName: x.name, type: 'image');
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.single;
    final file = File(f.path!);
    final ext = f.extension?.toLowerCase();
    final type = (ext == 'jpg' || ext == 'jpeg' || ext == 'png' || ext == 'gif') ? 'image' : 'file';
    await _uploadAndSend(file, originalName: f.name, type: type);
  }

  Future<void> _uploadAndSend(File file, {required String originalName, required String type}) async {
    setState(() => _sending = true);
    try {
      await _ensureRoom();
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final id = _uuid.v4();
      final ref = FirebaseStorage.instance.ref().child('attachments/${widget.roomId}/$id-$originalName');
      await ref.putFile(file);
      final url = await ref.getDownloadURL();
      final text = type == 'image' ? '[Image] $originalName' : '[File] $originalName';
      await _roomRef.add({
        'text': text,
        'senderId': uid,
        'createdAt': FieldValue.serverTimestamp(),
        'attachmentUrl': url,
        'attachmentName': originalName,
        'attachmentType': type,
      });
      await FirebaseFirestore.instance.collection('rooms').doc(widget.roomId).update({
        'lastActivity': FieldValue.serverTimestamp(),
        'lastMessage': text,
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return Scaffold(
      appBar: AppBar(title: Text(widget.roomId)),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _roomRef.orderBy('createdAt', descending: true).limit(200).snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data?.docs ?? [];
                return ListView.builder(
                  reverse: true,
                  itemCount: docs.length,
                  itemBuilder: (context, i) {
                    final m = docs[i].data();
                    final isMe = m['senderId'] == uid;
                    final text = m['text'] as String? ?? '';
                    final attachUrl = m['attachmentUrl'] as String?;
                    final attachType = m['attachmentType'] as String?;

                    Widget bubble = Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (attachUrl != null && attachType == 'image')
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.network(attachUrl, height: 160, fit: BoxFit.cover),
                            ),
                          ),
                        if (attachUrl != null && attachType == 'file')
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.attach_file),
                                const SizedBox(width: 6),
                                Flexible(child: Text(m['attachmentName'] ?? 'Attachment')),
                              ],
                            ),
                          ),
                        Text(text),
                      ],
                    );

                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isMe ? Colors.blue.shade100 : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: bubble,
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  IconButton(onPressed: _pickImage, icon: const Icon(Icons.image_outlined)),
                  IconButton(onPressed: _pickFile, icon: const Icon(Icons.attach_file)),
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendText(),
                      decoration: const InputDecoration(
                        hintText: 'Type a message',
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sending ? null : _sendText,
                    child: _sending
                        ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
