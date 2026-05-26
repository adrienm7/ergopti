// scripts/inject-locales.js

"use strict";

const fs = require("fs");
const path = require("path");

const LOCALES_DIR = path.join("d:", "Documents", "GitHub", "ergopti", "static", "locales");

const translations = {
	ar: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements غير متاح — تحقق من التثبيت.",
		"karabiner.onboarding.error.manifest_unconfigured": "لم يتم تكوين الملف التعريفي (توجد عناصر نائبة TODO).",
		"karabiner.onboarding.error.mount_failed": "فشل التحميل: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nسيتم تنزيل التطبيق من المستودع الرسمي (pqrs-org/Karabiner-Elements) وتثبيته تلقائيًا. سيُطلب منك كلمة مرور المسؤول.",
		"karabiner.onboarding.missing.daemon_not_running": "• الخدمة الخلفية غير قيد التشغيل (مراقبة الإدخال؟)",
		"karabiner.onboarding.missing.grabber_absent": "• خدمة karabiner_grabber غائبة",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements غير مثبت",
		"karabiner.onboarding.missing.sysext_not_activated": "• امتداد النظام (DriverKit) غير مفعّل",
	},
	cs: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements není dostupný — zkontrolujte instalaci.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest není nakonfigurován (přítomny zástupné hodnoty TODO).",
		"karabiner.onboarding.error.mount_failed": "Připojení selhalo: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nAplikace bude stažena z oficiálního repozitáře (pqrs-org/Karabiner-Elements) a automaticky nainstalována. Bude vyžádáno heslo správce.",
		"karabiner.onboarding.missing.daemon_not_running": "• Démon není spuštěn (Monitorování vstupu?)",
		"karabiner.onboarding.missing.grabber_absent": "• Démon karabiner_grabber chybí",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements není nainstalován",
		"karabiner.onboarding.missing.sysext_not_activated": "• Systémové rozšíření (DriverKit) není aktivováno",
	},
	da: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements er ikke tilgængelig — kontroller installationen.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest er ikke konfigureret (TODO-pladsholdere er til stede).",
		"karabiner.onboarding.error.mount_failed": "Montering mislykkedes: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nApplikationen downloades fra det officielle lager (pqrs-org/Karabiner-Elements) og installeres automatisk. Administratoradgangskoden vil blive anmodet.",
		"karabiner.onboarding.missing.daemon_not_running": "• Dæmonen kører ikke (Inputovervågning?)",
		"karabiner.onboarding.missing.grabber_absent": "• karabiner_grabber-dæmonen mangler",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements er ikke installeret",
		"karabiner.onboarding.missing.sysext_not_activated": "• Systemudvidelsen (DriverKit) er ikke aktiveret",
	},
	de: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements nicht verfügbar — Installation überprüfen.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest nicht konfiguriert (TODO-Platzhalter vorhanden).",
		"karabiner.onboarding.error.mount_failed": "Einbinden fehlgeschlagen: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nDie Anwendung wird aus dem offiziellen Repository (pqrs-org/Karabiner-Elements) heruntergeladen und automatisch installiert. Das Administratorkennwort wird abgefragt.",
		"karabiner.onboarding.missing.daemon_not_running": "• Der Daemon läuft nicht (Eingabeüberwachung?)",
		"karabiner.onboarding.missing.grabber_absent": "• Der karabiner_grabber-Daemon fehlt",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements ist nicht installiert",
		"karabiner.onboarding.missing.sysext_not_activated": "• Die Systemerweiterung (DriverKit) ist nicht aktiviert",
	},
	en: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements unavailable — check installation.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest not configured (TODO placeholders present).",
		"karabiner.onboarding.error.mount_failed": "Mount failed: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nThe application will be downloaded from the official repository (pqrs-org/Karabiner-Elements) and installed automatically. The administrator password will be requested.",
		"karabiner.onboarding.missing.daemon_not_running": "• The daemon is not running (Input Monitoring?)",
		"karabiner.onboarding.missing.grabber_absent": "• The karabiner_grabber daemon is absent",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements is not installed",
		"karabiner.onboarding.missing.sysext_not_activated": "• The system extension (DriverKit) is not activated",
	},
	es: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements no disponible — verifique la instalación.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifiesto no configurado (hay marcadores TODO pendientes).",
		"karabiner.onboarding.error.mount_failed": "Error al montar: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nLa aplicación se descargará del repositorio oficial (pqrs-org/Karabiner-Elements) y se instalará automáticamente. Se solicitará la contraseña de administrador.",
		"karabiner.onboarding.missing.daemon_not_running": "• El demonio no está en ejecución (¿Supervisión de entrada?)",
		"karabiner.onboarding.missing.grabber_absent": "• El demonio karabiner_grabber está ausente",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements no está instalado",
		"karabiner.onboarding.missing.sysext_not_activated": "• La extensión del sistema (DriverKit) no está activada",
	},
	fr: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements indisponible — vérifiez l'installation.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest non configuré (des espaces réservés TODO sont présents).",
		"karabiner.onboarding.error.mount_failed": "Échec du montage : {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nL'application sera téléchargée depuis le dépôt officiel (pqrs-org/Karabiner-Elements) et installée automatiquement. Le mot de passe administrateur sera demandé.",
		"karabiner.onboarding.missing.daemon_not_running": "• Le démon n'est pas en cours d'exécution (Surveillance des entrées ?)",
		"karabiner.onboarding.missing.grabber_absent": "• Le démon karabiner_grabber est absent",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements n'est pas installé",
		"karabiner.onboarding.missing.sysext_not_activated": "• L'extension système (DriverKit) n'est pas activée",
	},
	he: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements אינו זמין — בדוק את ההתקנה.",
		"karabiner.onboarding.error.manifest_unconfigured": "המניפסט אינו מוגדר (קיימים מציני מקום TODO).",
		"karabiner.onboarding.error.mount_failed": "הרכבה נכשלה: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nהאפליקציה תורד מהמאגר הרשמי (pqrs-org/Karabiner-Elements) ותותקן אוטומטית. תתבקש סיסמת מנהל המערכת.",
		"karabiner.onboarding.missing.daemon_not_running": "• השירות אינו פועל (ניטור קלט?)",
		"karabiner.onboarding.missing.grabber_absent": "• שירות karabiner_grabber נעדר",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements אינו מותקן",
		"karabiner.onboarding.missing.sysext_not_activated": "• הרחבת המערכת (DriverKit) אינה מופעלת",
	},
	hi: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements अनुपलब्ध — इंस्टॉलेशन जाँचें।",
		"karabiner.onboarding.error.manifest_unconfigured": "मैनिफ़ेस्ट कॉन्फ़िगर नहीं है (TODO प्लेसहोल्डर मौजूद हैं)।",
		"karabiner.onboarding.error.mount_failed": "माउंट विफल: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nएप्लिकेशन को आधिकारिक रिपॉजिटरी (pqrs-org/Karabiner-Elements) से डाउनलोड किया जाएगा और स्वचालित रूप से इंस्टॉल किया जाएगा। एडमिनिस्ट्रेटर पासवर्ड माँगा जाएगा।",
		"karabiner.onboarding.missing.daemon_not_running": "• डेमॉन नहीं चल रहा (इनपुट मॉनिटरिंग?)",
		"karabiner.onboarding.missing.grabber_absent": "• karabiner_grabber डेमॉन अनुपस्थित है",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements इंस्टॉल नहीं है",
		"karabiner.onboarding.missing.sysext_not_activated": "• सिस्टम एक्सटेंशन (DriverKit) सक्रिय नहीं है",
	},
	it: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements non disponibile — verificare l'installazione.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest non configurato (sono presenti segnaposto TODO).",
		"karabiner.onboarding.error.mount_failed": "Montaggio fallito: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nL'applicazione verrà scaricata dal repository ufficiale (pqrs-org/Karabiner-Elements) e installata automaticamente. Verrà richiesta la password di amministratore.",
		"karabiner.onboarding.missing.daemon_not_running": "• Il daemon non è in esecuzione (Monitoraggio input?)",
		"karabiner.onboarding.missing.grabber_absent": "• Il daemon karabiner_grabber è assente",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements non è installato",
		"karabiner.onboarding.missing.sysext_not_activated": "• L'estensione di sistema (DriverKit) non è attivata",
	},
	ja: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements が利用できません — インストールを確認してください。",
		"karabiner.onboarding.error.manifest_unconfigured": "マニフェストが設定されていません（TODO プレースホルダーが存在します）。",
		"karabiner.onboarding.error.mount_failed": "マウントに失敗しました: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nアプリケーションは公式リポジトリ（pqrs-org/Karabiner-Elements）からダウンロードされ、自動的にインストールされます。管理者パスワードが要求されます。",
		"karabiner.onboarding.missing.daemon_not_running": "• デーモンが実行されていません（入力監視？）",
		"karabiner.onboarding.missing.grabber_absent": "• karabiner_grabber デーモンが存在しません",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements がインストールされていません",
		"karabiner.onboarding.missing.sysext_not_activated": "• システム拡張（DriverKit）が有効化されていません",
	},
	ko: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements를 사용할 수 없습니다 — 설치를 확인하세요.",
		"karabiner.onboarding.error.manifest_unconfigured": "매니페스트가 구성되지 않았습니다 (TODO 자리 표시자가 있음).",
		"karabiner.onboarding.error.mount_failed": "마운트 실패: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\n애플리케이션이 공식 저장소(pqrs-org/Karabiner-Elements)에서 다운로드되어 자동으로 설치됩니다. 관리자 비밀번호가 요청됩니다.",
		"karabiner.onboarding.missing.daemon_not_running": "• 데몬이 실행되고 있지 않습니다 (입력 모니터링?)",
		"karabiner.onboarding.missing.grabber_absent": "• karabiner_grabber 데몬이 없습니다",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements가 설치되어 있지 않습니다",
		"karabiner.onboarding.missing.sysext_not_activated": "• 시스템 확장 프로그램(DriverKit)이 활성화되지 않았습니다",
	},
	nl: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements niet beschikbaar — controleer de installatie.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest niet geconfigureerd (TODO-plaatshouders aanwezig).",
		"karabiner.onboarding.error.mount_failed": "Koppelen mislukt: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nDe applicatie wordt gedownload uit de officiële repository (pqrs-org/Karabiner-Elements) en automatisch geïnstalleerd. Het beheerderswachtwoord wordt gevraagd.",
		"karabiner.onboarding.missing.daemon_not_running": "• De daemon draait niet (Invoerbewaking?)",
		"karabiner.onboarding.missing.grabber_absent": "• De karabiner_grabber-daemon ontbreekt",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements is niet geïnstalleerd",
		"karabiner.onboarding.missing.sysext_not_activated": "• De systeemextensie (DriverKit) is niet geactiveerd",
	},
	no: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements er ikke tilgjengelig — sjekk installasjonen.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest er ikke konfigurert (TODO-plassholdere er til stede).",
		"karabiner.onboarding.error.mount_failed": "Montering mislyktes: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nApplikasjonen lastes ned fra det offisielle lageret (pqrs-org/Karabiner-Elements) og installeres automatisk. Administratorpassordet vil bli etterspurt.",
		"karabiner.onboarding.missing.daemon_not_running": "• Daemonen kjører ikke (Inndataovervåking?)",
		"karabiner.onboarding.missing.grabber_absent": "• karabiner_grabber-daemonen mangler",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements er ikke installert",
		"karabiner.onboarding.missing.sysext_not_activated": "• Systemutvidelsen (DriverKit) er ikke aktivert",
	},
	pl: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements niedostępny — sprawdź instalację.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest nie jest skonfigurowany (obecne są symbole zastępcze TODO).",
		"karabiner.onboarding.error.mount_failed": "Montowanie nie powiodło się: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nAplikacja zostanie pobrana z oficjalnego repozytorium (pqrs-org/Karabiner-Elements) i zainstalowana automatycznie. Zostanie poproszone o hasło administratora.",
		"karabiner.onboarding.missing.daemon_not_running": "• Demon nie jest uruchomiony (Monitorowanie wejścia?)",
		"karabiner.onboarding.missing.grabber_absent": "• Demon karabiner_grabber jest nieobecny",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements nie jest zainstalowany",
		"karabiner.onboarding.missing.sysext_not_activated": "• Rozszerzenie systemowe (DriverKit) nie jest aktywowane",
	},
	pt: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements indisponível — verifique a instalação.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifesto não configurado (marcadores TODO presentes).",
		"karabiner.onboarding.error.mount_failed": "Falha ao montar: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nO aplicativo será baixado do repositório oficial (pqrs-org/Karabiner-Elements) e instalado automaticamente. A senha do administrador será solicitada.",
		"karabiner.onboarding.missing.daemon_not_running": "• O daemon não está em execução (Monitoramento de entrada?)",
		"karabiner.onboarding.missing.grabber_absent": "• O daemon karabiner_grabber está ausente",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements não está instalado",
		"karabiner.onboarding.missing.sysext_not_activated": "• A extensão do sistema (DriverKit) não está ativada",
	},
	ru: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements недоступен — проверьте установку.",
		"karabiner.onboarding.error.manifest_unconfigured": "Манифест не настроен (присутствуют заглушки TODO).",
		"karabiner.onboarding.error.mount_failed": "Ошибка монтирования: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nПриложение будет загружено из официального репозитория (pqrs-org/Karabiner-Elements) и установлено автоматически. Будет запрошен пароль администратора.",
		"karabiner.onboarding.missing.daemon_not_running": "• Демон не запущен (Мониторинг ввода?)",
		"karabiner.onboarding.missing.grabber_absent": "• Демон karabiner_grabber отсутствует",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements не установлен",
		"karabiner.onboarding.missing.sysext_not_activated": "• Системное расширение (DriverKit) не активировано",
	},
	sv: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements är inte tillgängligt — kontrollera installationen.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifestet är inte konfigurerat (TODO-platshållare finns).",
		"karabiner.onboarding.error.mount_failed": "Montering misslyckades: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nApplikationen laddas ned från det officiella arkivet (pqrs-org/Karabiner-Elements) och installeras automatiskt. Administratörslösenordet kommer att begäras.",
		"karabiner.onboarding.missing.daemon_not_running": "• Demonen körs inte (Inmatningsövervakning?)",
		"karabiner.onboarding.missing.grabber_absent": "• karabiner_grabber-demonen saknas",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements är inte installerat",
		"karabiner.onboarding.missing.sysext_not_activated": "• Systemtillägget (DriverKit) är inte aktiverat",
	},
	tr: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements kullanılamıyor — kurulumu kontrol edin.",
		"karabiner.onboarding.error.manifest_unconfigured": "Manifest yapılandırılmamış (TODO yer tutucuları mevcut).",
		"karabiner.onboarding.error.mount_failed": "Bağlama başarısız: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nUygulama resmi depodan (pqrs-org/Karabiner-Elements) indirilecek ve otomatik olarak kurulacaktır. Yönetici parolası istenecektir.",
		"karabiner.onboarding.missing.daemon_not_running": "• Daemon çalışmıyor (Giriş İzleme?)",
		"karabiner.onboarding.missing.grabber_absent": "• karabiner_grabber daemon'ı yok",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements kurulu değil",
		"karabiner.onboarding.missing.sysext_not_activated": "• Sistem uzantısı (DriverKit) etkinleştirilmemiş",
	},
	uk: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements недоступний — перевірте встановлення.",
		"karabiner.onboarding.error.manifest_unconfigured": "Маніфест не налаштований (присутні заглушки TODO).",
		"karabiner.onboarding.error.mount_failed": "Помилка монтування: {error}",
		"karabiner.onboarding.install_body_suffix": "\n\nДодаток буде завантажено з офіційного репозиторію (pqrs-org/Karabiner-Elements) та встановлено автоматично. Буде запрошено пароль адміністратора.",
		"karabiner.onboarding.missing.daemon_not_running": "• Демон не запущено (Моніторинг вводу?)",
		"karabiner.onboarding.missing.grabber_absent": "• Демон karabiner_grabber відсутній",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements не встановлено",
		"karabiner.onboarding.missing.sysext_not_activated": "• Системне розширення (DriverKit) не активовано",
	},
	zh: {
		"karabiner.lifecycle.unavailable": "Karabiner-Elements 不可用 — 请检查安装。",
		"karabiner.onboarding.error.manifest_unconfigured": "清单未配置（存在 TODO 占位符）。",
		"karabiner.onboarding.error.mount_failed": "挂载失败：{error}",
		"karabiner.onboarding.install_body_suffix": "\n\n应用程序将从官方仓库（pqrs-org/Karabiner-Elements）下载并自动安装。将请求管理员密码。",
		"karabiner.onboarding.missing.daemon_not_running": "• 守护进程未运行（输入监控？）",
		"karabiner.onboarding.missing.grabber_absent": "• karabiner_grabber 守护进程不存在",
		"karabiner.onboarding.missing.ke_not_installed": "• Karabiner-Elements 未安装",
		"karabiner.onboarding.missing.sysext_not_activated": "• 系统扩展（DriverKit）未激活",
	},
};

const files = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith(".json"));

for (const file of files) {
	const locale = path.basename(file, ".json");
	const filePath = path.join(LOCALES_DIR, file);

	const raw = fs.readFileSync(filePath, "utf8");
	const existing = JSON.parse(raw);

	const newKeys = translations[locale];
	if (!newKeys) {
		console.log(`SKIP  ${file} — no translations defined for locale "${locale}"`);
		continue;
	}

	const merged = Object.assign({}, existing, newKeys);

	const sorted = {};
	for (const key of Object.keys(merged).sort()) {
		sorted[key] = merged[key];
	}

	fs.writeFileSync(filePath, JSON.stringify(sorted, null, "\t") + "\n", "utf8");
	console.log(`OK    ${file} — ${Object.keys(newKeys).length} key(s) injected, ${Object.keys(sorted).length} total key(s)`);
}

console.log("\nDone.");
