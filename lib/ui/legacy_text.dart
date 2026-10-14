/// Render-time English-to-Farsi lookup for the legacy diagnostics page.
///
/// The legacy page keeps English copy in its widgets and localizes while
/// rendering, so switching language preserves every dialog's state.
library;

import 'package:flutter/material.dart';

import 'localization.dart';

// Advanced diagnostics retain the same controls as the earlier paired pilot.
// Localization is applied at render time so switching language preserves state.
class LegacyText extends StatelessWidget {
  const LegacyText(this.data, {super.key, this.style, this.textAlign});
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  @override
  Widget build(BuildContext context) {
    final fa = LanguageScope.isFarsi(context);
    return Text(
      fa ? (diagnosticFa[data] ?? data) : data,
      textAlign: textAlign,
      style: fa
          ? style?.copyWith(
              fontFamily: 'Vazirmatn',
              letterSpacing: 0,
              height: (style?.height ?? 1.5).clamp(1.5, 2),
            )
          : style,
    );
  }
}

String diagnostic(BuildContext context, String text) =>
    LanguageScope.isFarsi(context) ? (diagnosticFa[text] ?? text) : text;
const diagnosticFa = <String, String>{
  'FarvaharTrends': 'فروهر ترندز',
  'INDEPENDENT BY DESIGN': 'خبر، از مردم به مردم',
  'PILOT': 'آزمایشی',
  'Overview': 'دستگاه',
  'Peers': 'اعتماد دستی',
  'Bulletins': 'پیام آزمایش',
  'Results': 'نتایج',
  'News worth keeping connected.': 'آزمایش یک اتصال واقعی.',
  'A SMALL SIGNAL. A SHARED CONNECTION.': 'یک اتصال کوچک، یک جریان مشترک',
  'From peer to peer.\nVerified at every stop.':
      'از همتا به همتا.\nامضای هر پیام بررسی می‌شود.',
  'NO REQUIRED CENTRAL SERVER': 'بدون سرور مرکزی اجباری',
  'Preparing your device identity…': 'در حال آماده‌سازی هویت دستگاه…',
  'Receiving is on': 'دریافت فعال است',
  'Receiving is off': 'دریافت غیرفعال است',
  'Active Android mode': 'حالت فعال اندروید',
  'Standard comparison mode': 'حالت استاندارد مقایسه',
  'Your phone is ready when you are.': 'دستگاه برای دریافت آماده است.',
  'Start receiving': 'شروع دریافت',
  'Stop receiving': 'توقف دریافت',
  'Try standard mode for comparison': 'حالت استاندارد برای مقایسه',
  'CONNECTED PEERS': 'همتاهای متصل',
  'LOCKED + ≤ 5 MIN': 'قفل + حداکثر ۵ دقیقه',
  'Your device': 'وضعیت دستگاه',
  'A few conditions shape every connection.':
      'شرایط دستگاه بر اتصال اثر می‌گذارد.',
  'Network': 'شبکه',
  'Battery': 'باتری',
  'Charging': 'در حال شارژ',
  'Power saving': 'ذخیرهٔ انرژی',
  'Battery exemption': 'معافیت باتری',
  'Battery settings': 'تنظیمات باتری',
  'Not available': 'نامشخص',
  'On': 'فعال',
  'Off': 'غیرفعال',
  'Allowed': 'مجاز',
  'Not exempt': 'معاف نیست',
  'Unplugged': 'جدا از شارژ',
  'A trusted peer still needs a route.':
      'همتای مورد اعتماد هم به مسیر واقعی نیاز دارد.',
  'Pairing confirms identity. It cannot make two phones reachable through a provider’s NAT or a blocked network.': 'تبادل کارت، اعتماد به کلید را مشخص می‌کند؛ NAT اپراتور یا مسیر مسدود را برطرف نمی‌کند.',
  'Make your first connection': 'اولین اتصال آزمایشی',
  'A five-step guide to a meaningful trial.':
      'راهنمای پنج‌مرحله‌ای برای آزمایشی قابل بررسی.',
  'People make the network.': 'اعتماد دستی به همتاها',
  'Pair trusted test phones before you begin. Each phone imports the other’s card.':
      'برای آزمون کنترل‌شده، هر دستگاه کارت دستگاه دیگر را وارد کند.',
  'Your pairing card': 'کارت این دستگاه',
  'Trust only · no dialing address': 'فقط اعتماد · بدون نشانی اتصال',
  'Show pairing card': 'نمایش کارت من',
  'Paired peers': 'همتاهای مورد اعتماد',
  'Only explicitly trusted identities.':
      'کلیدهایی که دستی به آن‌ها اعتماد کرده‌اید.',
  'Import a peer card': 'وارد کردن کارت همتا',
  'Pair your first peer': 'اولین همتای آزمایشی را اضافه کنید',
  'Exchange cards with another test phone. Check the full fingerprint together before trusting it.': 'کارت‌ها را مبادله کنید و پیش از اعتماد، همهٔ بخش‌های اثر انگشت را مقایسه کنید.',
  'Keep trust and reachability separate.': 'اعتماد و دسترسی دو چیز جدا هستند.',
  'Manual addresses are optional. Automatic peer discovery also works across networks.': 'واردکردن نشانی دستی اختیاری است. برنامه همتاها را میان شبکه‌های مختلف هم به‌طور خودکار پیدا می‌کند.',
  'Connected': 'متصل',
  'Waiting for a route': 'منتظر مسیر اتصال',
  'Update address': 'ویرایش نشانی',
  'Remove trust': 'حذف اعتماد',
  'A signal you can verify.': 'پیام آزمایش امضاشده',
  'Small, signed test bulletins move between reachable paired phones.': 'پیام‌های کوچک آزمایش میان دستگاه‌های مورد اعتماد و قابل دسترس منتقل می‌شوند.',
  'Publish a test bulletin': 'ارسال پیام آزمایش',
  'Start receiving and pair a peer to publish.':
      'برای آزمایش، دریافت را فعال و یک همتا را اضافه کنید.',
  'Verified feed': 'پیام‌های با امضای معتبر',
  'Stored locally. Ready to pass along.':
      'ذخیره‌شده روی این دستگاه و آمادهٔ بازنشر.',
  'Your first bulletin starts here.': 'هنوز پیام آزمایشی دریافت نشده است.',
  'Publish harmless test text or receive a signed bulletin from a paired source.': 'متن بی‌خطر آزمایش را بفرستید یا پیام امضاشده از یک همتای مورد اعتماد دریافت کنید.',
  'SIGNATURE VERIFIED': 'امضای دیجیتال معتبر',
  'Signed at the source. Pinned between peers.':
      'امضاشده در مبدأ، اتصال به کلید مشخص.',
  'A valid signature confirms the trusted signer and protects the message from alteration. This pilot is for public, harmless test content.': 'امضا از تغییر پیام جلوگیری می‌کند؛ درستی خبر یا هویت انسانی ناشر را تضمین نمی‌کند. برای آزمایش از متن عمومی بی‌خطر استفاده کنید.',
  'Measure the connection.': 'اتصال را بسنجیم.',
  'Evidence from your own trials. Every paired recipient stays in the count.':
      'هر دریافت‌کنندهٔ ثبت‌شده در شمار آزمایش باقی می‌ماند.',
  'LOCKED DELIVERY · ≤ 5 MIN': 'دریافت قفل · حداکثر ۵ دقیقه',
  'Timely · unlocked': 'به‌موقع، بدون قفل',
  'Unproven / missing': 'اثبات‌نشده / ناموجود',
  'Confirmed only when a signed receipt returns to the source within five minutes and the receiver reports a known locked state.': 'تأیید فقط با بازگشت رسید امضاشده در مهلت پنج‌دقیقه‌ای و وضعیت قفل مشخص انجام می‌شود.',
  'Unknown is a limit of the evidence.': 'نامشخص، محدودیت شواهد است.',
  'A late or missing receipt, unknown lock state, or unavailable clock does not prove delivery failed. Locked state is sampled at receipt, not throughout the wait.': 'رسید دیرهنگام یا ناموجود، ساعت نامعتبر و وضعیت قفل نامشخص، شکست دریافت را ثابت نمی‌کنند. حالت قفل فقط هنگام دریافت ثبت می‌شود.',
  'Trial history': 'آزمایش‌های ثبت‌شده',
  'Fresh messages make a useful comparison.':
      'برای هر مقایسه، پیام تازه بفرستید.',
  'A clear result starts with a real trial.': 'هنوز آزمایشی ثبت نشده است.',
  'Pair phones, establish a route, then publish a fresh bulletin while a receiving phone is locked.':
      'مسیر اتصال را برقرار کنید و وقتی گیرنده قفل است، یک پیام تازه بفرستید.',
  'Export trial report': 'خروجی گزارش',
  'How to run a useful trial': 'راهنمای آزمایش قابل بررسی',
  'Close': 'بستن',
  'Copy card': 'کپی کارت',
  'Cancel': 'انصراف',
  'Review identity': 'بررسی هویت',
  'Fingerprint matches · trust': 'اثر انگشت مطابقت دارد',
  'Update peer address': 'ویرایش نشانی همتا',
  'Save address': 'ذخیرهٔ نشانی',
  'Remove this peer’s trust?': 'اعتماد به این همتا حذف شود؟',
  'Keep peer': 'نگه داشتن همتا',
  'Remove peer': 'حذف همتا',
  'Sign & publish': 'امضا و ارسال',
  'Export a trial report?': 'خروجی گزارش آزمایش؟',
  'Export report': 'خروجی گزارش',
  'Copy this card to the other phone. Compare the complete fingerprint together. Import their card here too.': 'این کارت را به دستگاه دیگر بدهید و همهٔ بخش‌های اثر انگشت را مقایسه کنید. کارت آن دستگاه را نیز اینجا وارد کنید.',
  'Paste the card shared by the other test phone.':
      'کارت دستگاه آزمایشی دیگر را اینجا وارد کنید.',
  'Paste the card shared by the other test phone, or a starting-peer list.':
      'کارت دستگاه آزمایشی دیگر یا فهرست همتاهای شروع را اینجا وارد کنید.',
  'Import a peer card or starting-peer list':
      'وارد کردن کارت همتا یا فهرست همتاهای شروع',
  'Share starting peers': 'اشتراک همتاهای شروع',
  'Copy list': 'کپی فهرست',
  'Starting-peer list copied': 'فهرست همتاهای شروع کپی شد',
  'Pairing card copied': 'کارت کپی شد',
  'A starting-peer list only introduces dialing addresses. It cannot sign news or change what this phone shares. Share it with people you know; it stays on this phone otherwise.': 'فهرست همتاهای شروع فقط نشانی اتصال را معرفی می‌کند؛ نمی‌تواند خبر امضا کند یا آنچه این گوشی به اشتراک می‌گذارد را تغییر دهد. آن را به افرادی که می‌شناسید بدهید؛ در غیر این صورت روی همین گوشی می‌ماند.',
  'Nothing shareable yet: give your card a public address or wait for helper contacts.': 'هنوز چیزی برای اشتراک نیست: به کارت خود نشانی عمومی بدهید یا منتظر مخاطب‌های یاری‌گر بمانید.',
  'This content is too large for a QR code. Use the copy button to share it as text.': 'این محتوا برای کد QR بیش از حد بزرگ است. با دکمهٔ کپی آن را به‌صورت متن به اشتراک بگذارید.',
  'Compare every group below with the fingerprint shown on the other phone, using a channel you trust.': 'همهٔ گروه‌های زیر را از یک مسیر مورد اعتماد با اثر انگشت دستگاه دیگر مقایسه کنید.',
  'This peer can send signed test bulletins and receive yours. A matching fingerprint confirms identity, not network reachability.': 'این همتا می‌تواند پیام امضاشده بفرستد و دریافت کند. تطابق اثر انگشت، دسترسی شبکه یا هویت انسانی را تضمین نمی‌کند.',
  'Use an address the other phone can reach. Wi-Fi addresses usually work only on the same local network.': 'نشانی باید از دستگاه مقابل قابل دسترس باشد. IP وای‌فای معمولاً فقط در همان شبکهٔ محلی کار می‌کند.',
  'Use fresh, harmless text for each trial. Paired phones can store and relay it.': 'برای هر آزمایش متن تازه و بی‌خطر بنویسید. همتاها می‌توانند آن را ذخیره و بازنشر کنند.',
  'Add a run ID and a message within the byte limit.':
      'شناسهٔ آزمایش و متن در محدودهٔ مجاز وارد کنید.',
  'The report contains public peer fingerprints, test labels, signed receipts, timing, device conditions, and trial outcomes. It excludes raw IP addresses, names, private keys, certificates, and message content. Identifiers and timing may link activity. Share it only with people you trust.': 'گزارش شامل اثر انگشت عمومی همتاها، برچسب آزمایش، رسیدها، زمان‌ها و شرایط دستگاه است. IP، نام، کلید خصوصی، گواهی و متن خبر در آن نیست. شناسه و زمان ممکن است فعالیت را به هم مرتبط کنند. فقط با افراد مورد اعتماد به اشتراک بگذارید.',
  'THE FIRST REAL TRIAL': 'اولین آزمایش واقعی',
  'Ready to begin': 'متوجه شدم',
};
