import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBUN9UbDnsD0K5E5DxGpGaoQs2xpLnNayE',
    appId: '1:911900427556:web:230e73ea3b3d1c0db51fb1',
    messagingSenderId: '911900427556',
    projectId: 'elite-by-s',
    authDomain: 'elite-by-s.firebaseapp.com',
    storageBucket: 'elite-by-s.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyALftq8qXtQALSE3U1Eq-weKUdd5olykA8',
    appId: '1:911900427556:android:48b3d6dcd96cc0e1b51fb1',
    messagingSenderId: '911900427556',
    projectId: 'elite-by-s',
    storageBucket: 'elite-by-s.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBo7b1MlMUiGdHMBDUIf2XVjWK3eWyVvOg',
    appId: '1:911900427556:ios:970d722b3514a254b51fb1',
    messagingSenderId: '911900427556',
    projectId: 'elite-by-s',
    storageBucket: 'elite-by-s.firebasestorage.app',
    iosBundleId: 'com.supportclub.carteNabil',
  );
}
