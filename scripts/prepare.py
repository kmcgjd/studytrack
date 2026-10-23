import json, re, shutil, subprocess, sys

PKG = 'com.studytrack.studytrack_app'
subprocess.check_call(['flutter', 'create', '--org', 'com.studytrack', '--project-name',
                       'studytrack_app', '--platforms', 'android', 'app'])
shutil.copy('pubspec.yaml', 'app/pubspec.yaml')
shutil.rmtree('app/lib')
shutil.copytree('lib', 'app/lib')
shutil.rmtree('app/test', ignore_errors=True)

try:
    g = json.load(open('google-services.json'))
except Exception:
    sys.exit('ERROR: google-services.json is missing from the repository. Upload it and run again.')
c = g['client'][0]
pkg = c['client_info']['android_client_info']['package_name']
if pkg != PKG:
    sys.exit('ERROR: Firebase Android package name is "%s" but must be "%s". '
             'Create a new Android app in Firebase with the correct package name.' % (pkg, PKG))
pi = g['project_info']
open('app/lib/firebase_options.dart', 'w').write("""import 'package:firebase_core/firebase_core.dart';

class DefaultFirebaseOptions {
  static const FirebaseOptions currentPlatform = FirebaseOptions(
    apiKey: '%s',
    appId: '%s',
    messagingSenderId: '%s',
    projectId: '%s',
    storageBucket: '%s',
  );
}
""" % (c['api_key'][0]['current_key'], c['client_info']['mobilesdk_app_id'],
       pi['project_number'], pi['project_id'], pi.get('storage_bucket', '')))

p = 'app/android/app/build.gradle'
s = open(p).read()
s, n = re.subn(r'minSdkVersion\s+flutter\.minSdkVersion', 'minSdkVersion 23', s)
if n == 0:
    sys.exit('ERROR: could not set minSdkVersion')
s, n = re.subn(r'(compileOptions\s*\{)', r'\1\n        coreLibraryDesugaringEnabled true', s, count=1)
if n == 0:
    sys.exit('ERROR: could not enable desugaring')
s += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'\n}\n"
open(p, 'w').write(s)

p = 'app/android/app/src/main/AndroidManifest.xml'
m = open(p).read()
perms = ('<uses-permission android:name="android.permission.INTERNET"/>\n'
         '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n'
         '    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>\n    ')
m = m.replace('<application', perms + '<application', 1)
rec = ('    <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>\n'
       '    <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">\n'
       '        <intent-filter>\n'
       '            <action android:name="android.intent.action.BOOT_COMPLETED"/>\n'
       '        </intent-filter>\n'
       '    </receiver>\n    ')
m = m.replace('</application>', rec + '</application>', 1)
m = re.sub(r'android:label="[^"]*"', 'android:label="StudyTrack"', m, count=1)
open(p, 'w').write(m)
print('Prepared OK')
