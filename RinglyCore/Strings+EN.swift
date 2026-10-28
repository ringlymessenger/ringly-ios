import Foundation

// Английские переводы. Ключ — русская строка из кода (см. Localization.swift).
//
// Отсутствующий ключ не ломает экран: `L()` вернёт сам ключ, и на месте перевода останется русская
// фраза. Это заметно при беглом просмотре и не требует отдельной проверки на «missing key».
enum Strings {
    static let en: [String: String] = [
        // ---- общее ----
        "Отмена": "Cancel",
        "Готово": "Done",
        "Далее": "Next",
        "Сохранить": "Save",
        "Сохранено": "Saved",
        "Удалить": "Delete",
        "Закрыть": "Close",
        "Понятно": "OK",
        "Ок": "OK",
        "Позже": "Later",
        "Ошибка": "Error",
        "Не получилось": "Something went wrong",
        "Поиск": "Search",
        "Это нельзя отменить.": "This cannot be undone.",

        // ---- вход и онбординг ----
        "Ошибка входа": "Sign-in error",
        "Безопасные звонки\nв любую точку мира": "Secure calls\nanywhere in the world",
        "Продолжить через Google": "Continue with Google",
        "Создание аккаунта": "Create account",
        "Укажите свои базовые данные, чтобы вашим друзьям было удобно вас найти":
            "Tell us the basics so your friends can find you",
        "Вы можете загрузить свою аватарку, шаг не обязательный":
            "You can upload a profile photo — this step is optional",
        "Имя": "First name",
        "Фамилия": "Last name",
        "Никнейм": "Username",
        "Никнейм: 3–32 символа, латиница, цифры и _": "Username: 3–32 characters, latin letters, digits and _",
        "Имя пользователя: 3–32 символа, латиница, цифры и _":
            "Username: 3–32 characters, latin letters, digits and _",
        "Добавить": "Add",
        "Изменить": "Change",

        // ---- чаты и сообщения ----
        "Чаты": "Chats",
        "Сообщение": "Message",
        "Подпись…": "Caption…",
        "печатает…": "typing…",
        "изменено": "edited",
        "Не отправлено": "Not sent",
        "Ответить": "Reply",
        "Переслать": "Forward",
        "Копировать": "Copy",
        "Копировать подпись": "Copy caption",
        "Изменение сообщения": "Editing message",
        "Удалить у всех": "Delete for everyone",
        "Удалить сообщение у всех?": "Delete message for everyone?",
        "Не удалось отправить": "Could not send",
        "Файл не отправлен": "File not sent",
        "Нажмите, чтобы убрать": "Tap to remove",
        "Подготовка…": "Preparing…",
        "Вы заблокировали этого пользователя": "You blocked this user",
        "Код безопасности с собеседником изменился (возможно, переустановил приложение).":
            "The safety number with this contact has changed (they may have reinstalled the app).",
        "Пользователь не найден. Введите точный @username целиком.":
            "User not found. Enter the exact @username.",
        "Имя недоступно на этом устройстве": "Name unavailable on this device",

        // ---- профиль контакта ----
        "Профиль": "Profile",
        "В сети": "Online",
        "Аудио": "Voice",
        "Видео": "Video",
        "Чат": "Chat",
        "Без звука": "Mute",
        "Вкл. звук": "Unmute",
        "Имя пользователя": "Username",
        "Ссылка скопирована": "Link copied",
        "Заблокировать": "Block",
        "Разблокировать": "Unblock",
        "Пожаловаться": "Report",
        "Удалить контакт": "Delete contact",
        "Удалить контакт?": "Delete contact?",
        "Переписка будет удалена у вас и у собеседника. Это нельзя отменить.":
            "The conversation will be deleted for both of you. This cannot be undone.",

        // ---- жалоба ----
        "Что произошло (необязательно)": "What happened (optional)",
        "Опишите ситуацию": "Describe the situation",
        "Отправить": "Send",
        "Переписка зашифрована, и сервер её не видит. Эти сообщения будут отправлены в открытом виде — только они, только по вашему выбору. Фото и видео не прикладываются.":
            "Your conversation is encrypted and the server cannot read it. These messages will be sent in plain text — only these, only if you choose to. Photos and videos are never attached.",

        // ---- свой профиль ----
        "Выйти": "Sign out",
        "Выйти из аккаунта": "Sign out",
        "Выйти из аккаунта?": "Sign out?",
        "Выйти и удалить данные": "Sign out and delete data",
        "Выйти из аккаунта? История чатов останется на устройстве и вернётся при повторном входе в этот же аккаунт.":
            "Sign out? Your chat history stays on this device and returns when you sign back into the same account.",
        "История чатов будет удалена с этого устройства. Если у вас нет других устройств с этой перепиской, она будет потеряна навсегда. PIN-бэкап сохраняет только ключ профиля, не историю.":
            "Chat history will be deleted from this device. If you have no other device with this conversation, it will be lost forever. The PIN backup stores only your profile key, not the history.",
        "Изменить профиль": "Edit profile",
        "Фото шифруется на устройстве": "The photo is encrypted on your device",
        "Имя и фамилия зашифрованы — сервер их не видит. Имя пользователя видно всем: по нему вас находят и работает ссылка-приглашение.":
            "Your first and last name are encrypted — the server cannot see them. Your username is public: it is how people find you and how invite links work.",
        "Удалить аккаунт": "Delete account",
        "Удалить аккаунт?": "Delete account?",
        "Удалить навсегда": "Delete permanently",
        "Удаление аккаунта…": "Deleting account…",
        "Это действие необратимо. Будут удалены ваш профиль, имя пользователя @%@, все устройства, ключи шифрования и переписки. Восстановить аккаунт и историю будет невозможно — даже с PIN-кодом.":
            "This cannot be undone. Your profile, the username @%@, all devices, encryption keys and conversations will be deleted. Restoring the account and its history will be impossible — even with a PIN.",
        "Не удалось удалить аккаунт": "Could not delete account",
        "Проверьте подключение к интернету и попробуйте ещё раз. Данные не изменились.":
            "Check your internet connection and try again. Nothing was changed.",

        // ---- настройки ----
        "Оформление": "Appearance",
        "Тёмная": "Dark",
        "Светлая": "Light",
        "Тёмная тема включена по умолчанию. Выбор сохраняется только на этом устройстве.":
            "Dark theme is on by default. Your choice is saved on this device only.",
        "Язык": "Language",
        "Системный": "System",
        "Язык интерфейса. «Системный» следует настройкам телефона; если системный язык не русский, интерфейс будет английским.":
            "Interface language. “System” follows your phone settings; if the system language is not Russian, the interface will be English.",

        // ---- чёрный список ----
        "Заблокированные": "Blocked",
        "Нет заблокированных пользователей": "No blocked users",

        // ---- устройства ----
        "Устройства": "Devices",
        "Устройства не найдены": "No devices found",
        "Отвязать": "Unlink",
        "Отвязать устройство?": "Unlink device?",
        "Это устройство перестанет получать сообщения и звонки. Если им ещё пользуются, придётся войти в аккаунт заново.":
            "This device will stop receiving messages and calls. If it is still in use, you will need to sign in again there.",
        "Если вы переустанавливали приложение или меняли телефон, здесь могут остаться старые записи. Отвяжите их — иначе сообщения продолжат шифроваться и для них.":
            "If you reinstalled the app or changed phones, stale entries may remain here. Unlink them — otherwise messages keep being encrypted for them too.",

        // ---- звонки ----
        "Звонки": "Calls",
        "Звонить через сервер": "Route calls through the server",
        "Логи": "Logs",
        "Журнал пуст — сделай звонок": "No calls yet",

        // ---- медиа и хранилище ----
        "Медиа и хранилище": "Media and storage",
        "Автозагрузка": "Auto-download",
        "Не больше": "No larger than",
        "занято медиафайлами": "used by media",
        "Очистить": "Clear",
        "Очистить медиафайлы": "Clear media",
        "Удалить все медиафайлы?": "Delete all media?",
        "Фото и видео будут удалены с этого устройства. Те, что ещё хранятся на сервере, можно будет скачать повторно; более старые восстановить не получится.":
            "Photos and videos will be deleted from this device. Those still stored on the server can be downloaded again; older ones cannot be recovered.",
        "Фото и видео зашифрованы и хранятся на этом устройстве. Сервер держит их временно — только пока сообщение не доставлено.":
            "Photos and videos are encrypted and stored on this device. The server keeps them only until the message is delivered.",
        "Поэтому старые файлы, удалённые здесь, восстановить будет невозможно, а при потере устройства медиа не сохранится.":
            "So files deleted here cannot be restored, and media will not survive the loss of this device.",

        // ---- PIN-бэкап и восстановление ----
        "Восстановление профиля": "Profile recovery",
        "Восстановить": "Restore",
        "Введите PIN": "Enter PIN",
        "Отправить снова": "Send again",
        "Сообщение не отправлено": "Message not sent",
        "Переслано: %@": "Forwarded to %@",
        "Переслано в чаты: %@": "Forwarded to %@ chats",
        "Нет доступа к фото — разрешите в Настройках": "No access to Photos — allow it in Settings",
        "Новый PIN": "New PIN",
        "От 4 цифр": "At least 4 digits",
        "Ещё раз": "Once more",
        "PIN не совпадает": "PINs don't match",
        "Запомните PIN: он понадобится, если вы потеряете все устройства. Восстановить его нельзя.": "Remember your PIN: you'll need it if you lose all your devices. It can't be recovered.",
        "Микрофон": "Mute",
        "Динамик": "Speaker",
        "Камера": "Flip",
        "Завершить": "End",
        "Отклонить": "Decline",
        "Принять": "Accept",
        "Отменить": "Cancel",
        "Введите PIN, который вы задали для резервной копии. Имя, аватар и профили контактов расшифруются после восстановления ключа.":
            "Enter the PIN you set for your backup. Your name, photo and contact profiles will be decrypted once the key is restored.",
        "Если вы откроете приложение на другом устройстве, где профиль доступен, ключ восстановится автоматически — этот экран закроется сам.":
            "If you open the app on another device where your profile is available, the key restores automatically and this screen closes by itself.",

        // ---- Rings и гудок ----
        "Баланс": "Balance",
        "Получить Rings": "Get Rings",
        "Посмотреть рекламу": "Watch an ad",
        "Кастомный гудок": "Custom ringback",
        "Пока вам звонят, собеседник слышит вашу мелодию вместо стандартного гудка.":
            "While your phone rings, the caller hears your melody instead of the standard ringback tone.",
        "Услуга неактивна. Выберите период, чтобы включить:": "Inactive. Choose a period to enable:",
        "Продлить": "Extend",
        "Удалить мелодию": "Delete melody",
        "MP3 любой длины. Звонящий услышит первые 45 секунд — столько длится дозвон. Громкость выровняется автоматически.":
            "MP3 of any length. Callers hear the first 45 seconds, which is how long a call rings. Volume is levelled automatically.",

        // ---- служебное меню ----
        "Служебное меню": "Debug menu",
        "Полный сброс…": "Full reset…",
        "Стереть": "Erase",
        "Стереть всё с этого устройства?": "Erase everything on this device?",
        "Удалит ключи, профиль и историю чатов на этом устройстве. Приложение закроется — открой его заново.":
            "Deletes keys, profile and chat history on this device. The app will quit — open it again.",

        // ---- вторая волна: экраны настроек, звонки, медиа ----
        "Чёрный список": "Blocked users",
        "Резервная копия (PIN)": "Backup (PIN)",
        "Восстановить профиль (PIN)": "Restore profile (PIN)",
        "PIN (от 4 цифр)": "PIN (4 digits or more)",
        "Повторите PIN": "Repeat PIN",
        "Диагностика": "Diagnostics",
        "Пользователи": "Users",
        "Вы": "You",
        "Устройство": "Device",
        "это устройство": "this device",
        "Ни разу не выходило на связь": "Never connected",
        "Имя недоступно": "Name unavailable",

        // связь
        "Соединение…": "Connecting…",
        "Обновление…": "Updating…",
        "Обработка…": "Processing…",
        "Переподключение…": "Reconnecting…",

        // звонки
        "Звонок": "Call",
        "Вызов…": "Calling…",
        "Входящий звонок": "Incoming call",
        "Входящий видеозвонок": "Incoming video call",
        "Звонок завершён": "Call ended",
        "Звонок отклонён": "Call declined",
        "Нет ответа": "No answer",
        "Занято": "Busy",
        "Не удалось установить соединение": "Could not connect",
        "Сервер для звонков недоступен.\nОтключите «Звонить через сервер» в настройках, чтобы позвонить напрямую.":
            "The call server is unavailable.\nTurn off “Route calls through the server” in settings to call directly.",
        "Обычно звонок идёт напрямую между устройствами — это быстрее и не нагружает сервер, но собеседник видит ваш IP-адрес.":
            "Calls normally go directly between devices — that is faster and lighter on the server, but the other person sees your IP address.",
        "Если включить, звонки пойдут через сервер Ringly. Собеседник не увидит ваш IP-адрес. Задержка может немного вырасти.":
            "When enabled, calls go through the Ringly server. The other person will not see your IP address. Latency may rise slightly.",
        "Содержимое звонка зашифровано в обоих случаях — сервер не может его слышать.":
            "Call content is encrypted either way — the server cannot listen to it.",

        // медиа
        "Фото": "Photo",
        "Недоступно": "Unavailable",
        "Всегда": "Always",
        "Никогда": "Never",
        "Только по Wi-Fi": "Wi-Fi only",
        "Файл больше 25 МБ": "File is larger than 25 MB",
        "Не удалось прочитать файл": "Could not read the file",
        "Файл не загрузился. Выберите его ещё раз.": "The file was not uploaded. Please pick it again.",
        "Файл больше недоступен — переслать нечего.": "The file is no longer available — nothing to forward.",
        "Переслано": "Forwarded",
        "Переслано от вас": "Forwarded from you",
        "Сообщение старше 48 часов — редактировать нельзя": "Messages older than 48 hours cannot be edited",

        // Rings
        "7 дней": "7 days",
        "30 дней": "30 days",
        "90 дней": "90 days",
        "Загрузить мелодию (MP3)": "Upload melody (MP3)",
        "Заменить мелодию": "Replace melody",
        "Реклама сейчас недоступна. Попробуйте позже.": "Ads are unavailable right now. Try again later.",
        "Слишком часто. Подождите минуту и попробуйте снова.": "Too many attempts. Wait a minute and try again.",

        // ---- сетевые ошибки ----
        "Ошибка сервера (%d)": "Server error (%d)",
        "Не удалось разобрать ответ": "Could not read the response",
        "Проблема с сетью": "Network problem",
        "Нет устройств получателя": "The recipient has no devices",
        "Не удалось зашифровать сообщение": "Could not encrypt the message",

        // ---- присутствие ----
        "в сети": "online",
        "не в сети": "offline",
        "был(а) в сети %@": "last seen %@",
        "только что": "just now",
        "%d мин назад": "%d min ago",
        "сегодня в %@": "today at %@",
        "вчера в %@": "yesterday at %@",
        "%@ в %@": "%@ at %@",

        // ---- просмотр медиа ----
        "Показать в чате": "Show in chat",
        "Сохранить фото": "Save photo",
        "Сохранить видео": "Save video",
        "Не удалось сохранить": "Couldn't save",
        "В ответ %@": "Reply to %@",
        "Недавние": "Recents",
        "Добавить комментарий…": "Add a comment…",
        "Добавить подпись…": "Add a caption…",
        "Доступ только к выбранным фото": "Access to selected photos only",
        "Нет доступа к фото": "No access to photos",
        "Разрешите доступ в Настройках — или выберите файлы через системное окно.": "Allow access in Settings — or pick files with the system picker.",
        "Выбрать в галерее": "Choose from library",
        "Открыть Настройки": "Open Settings",

        // ---- итоги звонков ----
        "Исходящий звонок": "Outgoing call",
        "Исходящий видеозвонок": "Outgoing video call",
        "Неотвеченный звонок": "Unanswered call",
        "Неотвеченный видеозвонок": "Unanswered video call",
        "Отклонённый звонок": "Declined call",
        "Отклонённый видеозвонок": "Declined video call",
        "Пропущенный звонок": "Missed call",
        "Пропущенный видеозвонок": "Missed video call",
        "Видеозвонок отклонён": "Video call declined",

        // ---- причины жалобы ----
        "Спам или мошенничество": "Spam or fraud",
        "Оскорбления и угрозы": "Abuse or threats",
        "Материалы с детьми": "Child sexual abuse material",
        "Выдаёт себя за другого": "Impersonation",
        "Другое": "Other",
        "Приложить последние %@": "Attach the last %@",

        // ---- уведомления ----
        "Новое сообщение": "New message",

        // ---- сервисы: гудок, PIN-бэкап, качество связи ----
        "В файле нет аудиодорожки": "The file has no audio track",
        "Пустой результат обработки": "Processing produced an empty result",
        "Мелодия загружена": "Melody uploaded",
        "Мелодия удалена": "Melody deleted",
        "Услуга активирована": "Service activated",
        "Начисление скоро появится": "The reward will arrive shortly",
        "На этом устройстве нет ключа профиля для бэкапа": "This device has no profile key to back up",
        "Повреждённые данные бэкапа": "Corrupted backup data",
        "Неверный PIN": "Wrong PIN",
        "Слишком много попыток. Попробуйте позже": "Too many attempts. Try again later",
        "плохо": "poor",
        "средне": "fair",
        "хорошо": "good",

        // ---- обход блокировок ----
        "Обход блокировок": "Censorship bypass",
        "Своя точка входа": "Your own entry point",
        "Подключение": "Connection",
        "Напрямую": "Direct",
        "Без обхода": "No bypass",
        "Порт": "Port",
        "Подключить": "Connect",
        "Подключение…": "Connecting…",
        "Подключено": "Connected",
        "Доступен": "Reachable",
        "Недоступен": "Unavailable",
        "Выдан автоматически": "Assigned automatically",
        "Перед выходом копия в iCloud обновится, и переписка вернётся при следующем входе после ввода PIN-кода. С этого устройства история будет удалена.":
            "Before you sign out, your iCloud backup will be updated, and your chats will come back the next time you sign in and enter your PIN. History will be deleted from this device.",
        "Код-пароль восстановить нельзя. Можно выйти из аккаунта: перед выходом копия в iCloud обновится, и переписка вернётся после входа по PIN-коду. С этого устройства история удалится.":
            "The passcode can't be recovered. You can sign out: your iCloud backup will be updated first, and your chats will come back after signing in with your PIN. History will be deleted from this device.",
        "Не удалось обновить копию в iCloud": "Couldn't update the iCloud backup",
        "Выйти всё равно": "Sign Out Anyway",
        "Сообщения новее последней копии (%@) будут потеряны. Можно проверить подключение и попробовать ещё раз.":
            "Messages newer than the last backup (%@) will be lost. You can check your connection and try again.",
        "Сохраняем переписку в iCloud…": "Saving chats to iCloud…",
        "Восстанавливаем переписку…": "Restoring your chats…",
        "Удалить точку входа?": "Delete entry point?",
        "Чтобы вернуть её, снова понадобится ссылка.": "To get it back, you will need the link again.",
        "Нажмите на строку, чтобы подключиться. Свою точку входа можно удалить долгим нажатием.":
            "Tap a row to connect. You can delete your own entry point with a long press.",
        "Имитировать блокировку": "Simulate blocking",
        "Имитировать блокировку звонков": "Simulate call blocking",
        "Тест рекламы": "Ad test",
        "Экран LevelPlay: идентификатор этого устройства для тестовых устройств в дашборде и проверка загрузки и показа рекламы.":
            "LevelPlay screen: this device's ID for test devices in the dashboard, plus an ad load and display check.",
        "Реклама уже запущена без тестового режима. Закрой приложение полностью, открой снова и нажми ещё раз.":
            "Ads are already running without test mode. Fully close the app, open it again and tap once more.",
        "Реклама недоступна.": "Ads are unavailable.",
        "Персонализированная реклама": "Personalized ads",
        "%@ использует свой гудок": "%@ uses a custom ringback tone",
        "Эти 45 секунд услышит звонящий": "Callers will hear these 45 seconds",
        "Пауза": "Pause",
        "Прослушать": "Listen",
        "Двигайте волну, чтобы выбрать момент": "Drag the waveform to pick the moment",
        "Фрагмент гудка": "Ringback clip",
        "Не удалось открыть файл": "Couldn't open the file",
        "Продлить на %@?": "Extend for %@?",
        "Включить на %@?": "Turn on for %@?",
        "Купить": "Buy",
        "Спишется %@ Rings. Гудок будет работать до %@.": "%@ Rings will be charged. Your ringback tone will work until %@.",
        "Такой можно поставить себе за Rings": "You can set one too with Rings",
        "Разрешить": "Allow",
        "Не разрешать": "Don't allow",
        "Rings зарабатываются просмотром рекламы от Unity. Разрешить подбирать её по данным об устройстве и о том, как вы смотрите рекламу? Реклама будет в любом случае, выбор можно изменить на этом экране.":
            "You earn Rings by watching ads from Unity. Allow ads to be tailored using data about your device and how you watch ads? Ads will be shown either way, and you can change this on this screen.",
        "Звонок идёт только через волонтёрский TURN или через мостик: центральный сервер напрямую и прямое соединение недоступны, как в худшем случае при блокировке. Если нет ни того, ни другого, звонок не соединится. Какой путь выдан — в логах (🧊).":
            "Calls go only through a volunteer TURN or through the bridge: the central server and direct connections are unavailable, as in the worst blocking case. If neither is available, the call will not connect. The assigned path is shown in the logs (🧊).",
        "Прямой путь к серверу перестаёт работать, мостики — нет. Так можно проверить переключение на мостик там, где Ringly не заблокирован. Сначала выбери «Напрямую» в Профиль → Обход блокировок. Не забудь выключить.":
            "The direct path to the server stops working, bridges keep working. This lets you test switching to a bridge where Ringly is not blocked. First pick “Direct” in Profile → Censorship bypass. Don't forget to turn it off.",
        "Включена имитация блокировки: прямое подключение не работает. Выключается в служебном меню.":
            "Blocking simulation is on: the direct connection does not work. Turn it off in the debug menu.",
        "%d мс": "%d ms",
        "Не удалось добавить": "Could not add",
        "Такая точка входа уже добавлена": "This entry point is already added",
        "Это не похоже на ссылку-мостик. Она должна начинаться с ringly-bridge://":
            "That doesn't look like a bridge link. It should start with ringly-bridge://",
        "В этой сборке обход недоступен: приложение собрано без компонента обхода. Точки входа можно добавить, но использоваться они не будут.":
            "Bypass is unavailable in this build: the app was compiled without the bypass component. You can add entry points, but they will not be used.",
        "Точка входа — это чужой (или ваш) сервер, который передаёт зашифрованный трафик до Ringly. Прочитать переписку он не может: шифрование сквозное. Ссылку выдаёт команда `ringly-relay link` на сервере.":
            "An entry point is someone else's (or your own) server that forwards encrypted traffic to Ringly. It cannot read your messages: encryption is end-to-end. The link is produced by the `ringly-relay link` command on the server.",
        "Нет связи с сервером": "Cannot reach Ringly",
        "Похоже, доступ к Ringly ограничен вашим провайдером, а запасных точек входа приложение пока не знает.\n\nВключите VPN на одну минуту и откройте приложение — оно получит запасные адреса и дальше будет работать само. Либо откройте ссылку-приглашение от того, у кого Ringly работает.":
            "It looks like your network is blocking Ringly, and the app doesn't know any backup entry points yet.\n\nTurn on a VPN for a minute and open the app — it will fetch backup addresses and keep working on its own afterwards. Or open an invite link from someone for whom Ringly works.",
        // код-пароль (AppLock)
        "Код-пароль": "Passcode",
        "Включить код-пароль": "Turn Passcode On",
        "Выключить код-пароль": "Turn Passcode Off",
        "Выключить код-пароль?": "Turn passcode off?",
        "Выключить": "Turn Off",
        "Сменить код-пароль": "Change Passcode",
        "Введите код-пароль": "Enter Passcode",
        "Введите новый код-пароль": "Enter New Passcode",
        "Придумайте код-пароль": "Create a Passcode",
        "Повторите код-пароль": "Repeat Passcode",
        "Коды не совпадают, попробуйте ещё раз": "Passcodes don't match, try again",
        "Неверный код-пароль": "Wrong passcode",
        "Забыли код-пароль?": "Forgot passcode?",
        "Код-пароль восстановить нельзя. Можно выйти из аккаунта — история чатов на этом устройстве будет удалена, как при обычном выходе.":
            "A passcode can't be recovered. You can log out — chat history on this device will be deleted, as with a regular logout.",
        "Слишком много попыток. Повторите через %@": "Too many attempts. Try again in %@",
        "сек": "s",
        "Автоблокировка": "Auto-Lock",
        "Сразу": "Immediately",
        "Через 1 минуту": "After 1 minute",
        "Через 5 минут": "After 5 minutes",
        "Через 1 час": "After 1 hour",
        "Через 5 часов": "After 5 hours",
        "Разблокировка %@": "Unlock with %@",
        "Разблокировка Ringly": "Unlock Ringly",
        "Ввести код": "Enter Passcode",
        "Не удалось включить %@": "Couldn't turn on %@",
        "Лица или отпечатки в телефоне изменились — введите код-пароль. %@ можно включить снова в настройках.":
            "Faces or fingerprints on this phone have changed — enter your passcode. You can turn %@ back on in settings.",
        "Ringly будет спрашивать код-пароль при открытии. Он отличается от кода телефона: кто знает пароль от телефона, в Ringly без вашего кода не войдёт.\n\nЕсли забыть код, восстановить его нельзя — останется только выйти из аккаунта: история чатов удалится с этого устройства. Если включена копия в iCloud, переписка вернётся после входа по PIN-коду.":
            "Ringly will ask for the passcode when you open it. It's separate from your phone's passcode: someone who knows your phone's passcode still can't open Ringly without yours.\n\nIf you forget it, it can't be recovered — the only way out is to log out: chat history will be deleted from this device. If iCloud backup is on, your chats come back after signing in with your PIN.",
        "Сохранение…": "Saving…",
        "Изменить имя": "Edit Name",
        "Имя контакта": "Contact Name",
        "Сбросить": "Reset",
        "Это имя видите только вы, на этом устройстве.": "Only you see this name, on this device.",
        "Логин": "Username",
        "Пароль": "Password",
        "Войти": "Sign In",
        "Демо-аккаунт": "Demo Account",
        "Вход по паролю есть только у демо-аккаунта для проверки приложения.": "Password sign-in is only available for the app review demo account.",
        "В iCloud есть копия, но ключа к ней на этом устройстве нет. Включите Связку ключей iCloud: Настройки → ваше имя → iCloud → Пароли и Связка ключей.": "There is a backup in iCloud, but its key isn't on this device. Turn on iCloud Keychain: Settings → your name → iCloud → Passwords and Keychain.",
        "В iCloud есть копия. Восстановите её, чтобы это устройство продолжило её обновлять.": "There is a backup in iCloud. Restore it so this device can keep it up to date.",
        "В iCloud есть копия: %d сообщений. Восстановите её, чтобы это устройство продолжило её обновлять.": "There is a backup in iCloud: %d messages. Restore it so this device can keep it up to date.",
        "В iCloud закончилось место": "iCloud storage is full",
        "Введите PIN, чтобы защитить копию. Без него в iCloud ничего не сохраняется.": "Enter your PIN to protect the backup. Nothing is saved to iCloud without it.",
        "Ввести PIN": "Enter PIN",
        "Войдите в iCloud в настройках iPhone и разрешите iCloud для Ringly — без этого копия не делается.": "Sign in to iCloud in iPhone Settings and allow iCloud for Ringly — the backup can't be made without it.",
        "Восстановить из iCloud": "Restore from iCloud",
        "Восстановление из iCloud…": "Restoring from iCloud…",
        "Делать копию на этом устройстве": "Back Up on This Device",
        "Задайте PIN, чтобы включить копию. Без него в iCloud ничего не сохраняется.": "Set a PIN to turn on the backup. Nothing is saved to iCloud without it.",
        "Задать PIN": "Set PIN",
        "Копию делает «%@», последняя копия: %@.": "Backed up by “%@”, last backup: %@.",
        "Копия в iCloud не найдена": "No backup found in iCloud",
        "Копия в iCloud": "iCloud Backup",
        "Копия выключена": "Backup is off",
        "Копия ещё не создана": "No backup yet",
        "Копия зашифрована. Ключ состоит из двух частей: одна лежит в Связке ключей iCloud, другая защищена вашим PIN. Ни Apple, ни Ringly прочитать копию не могут.": "The backup is encrypted. Its key has two parts: one is in iCloud Keychain, the other is protected by your PIN. Neither Apple nor Ringly can read it.",
        "Копия не обновлена: на устройстве намного меньше сообщений, чем в копии. Нажмите «Создать копию сейчас», если так и задумано.": "Backup not updated: this device has far fewer messages than the backup. Tap “Back Up Now” if this is intended.",
        "Копия переписки в iCloud": "Back Up Chats to iCloud",
        "Не удалось восстановить переписку. Попробуйте позже в Профиль → Копия в iCloud.": "Couldn't restore chats. Try again later in Profile → iCloud Backup.",
        "Нет связи с iCloud, повторим позже": "Can't reach iCloud, will retry later",
        "Оставить в iCloud": "Keep in iCloud",
        "Переписка сохраняется в вашем iCloud и переживает выход из аккаунта и смену телефона.": "Your chats are saved to your iCloud and survive signing out and switching phones.",
        "Последняя копия: %@": "Last backup: %@",
        "Создать копию сейчас": "Back Up Now",
        "Создаётся копия…": "Backing up…",
        "Тот же PIN, что защищает ключ профиля.": "The same PIN that protects your profile key.",
        "Удалить из iCloud": "Delete from iCloud",
        "Удалить уже сохранённую копию из iCloud?": "Delete the existing backup from iCloud?",
        "Не удалось создать копию. Попробуем ещё раз позже.": "Couldn't create the backup. We'll try again later.",
        "Без Связки ключей iCloud копия не восстановится на другом устройстве. В копию попадают фото и видео, которые есть на этом устройстве.": "Without iCloud Keychain the backup can't be restored on another device. Photos and videos stored on this device are included.",
        "Удалить из iCloud уже сохранённые медиа, которые теперь не подходят?": "Delete already saved media that no longer fits from iCloud?",
        "Загрузка медиа из iCloud: %d из %d": "Downloading media from iCloud: %d of %d",
        "Медиа в копию: %d из %d": "Backing up media: %d of %d",
        "В копии: сообщений — %d, медиа — %d (%@)": "In backup: %d messages, %d media (%@)",
        "Медиа": "Media",
        "Размер файла": "File Size",
        "Медиа по сотовой сети": "Media over Cellular",
        "Медиа только на зарядке": "Media Only While Charging",
        "Фото и видео": "Photos and Videos",
        "Только фото": "Photos Only",
        "Не сохранять": "Don't Save",
        "Без ограничения": "No Limit",
        "До %d МБ": "Up to %d MB",
        "PIN резервной копии": "Backup PIN",
        "PIN защищает ключ профиля и копию переписки в iCloud. Без него не восстановить ни профиль, ни переписку на новом устройстве. Сервер PIN не узнает.": "The PIN protects your profile key and your chat backup in iCloud. Without it you can't restore either on a new device. The server never learns your PIN.",
        "Сбросить копию в iCloud?": "Reset iCloud Backup?",
        "Сбросить копию": "Reset Backup",
        "Текущая копия будет удалена из iCloud, новая создастся из переписки на этом устройстве. Понадобится задать новый PIN.": "The current backup will be deleted from iCloud and a new one will be created from the chats on this device. You'll need to set a new PIN.",
        "Забыли PIN?": "Forgot PIN?",
        "Копия в iCloud зашифрована другим ключом. Если PIN меняли на другом устройстве — введите новый PIN.": "The iCloud backup is encrypted with a different key. If you changed your PIN on another device, enter the new PIN.",
        "Введите PIN, чтобы включить копию переписки в iCloud": "Enter your PIN to turn on the chat backup in iCloud",
        "Нет подключения к Wi-Fi": "No Wi-Fi Connection",
        "Продолжить с медиа": "Continue with Media",
        "Продолжить без медиа": "Continue without Media",
        "Фото и видео сохраняются только по Wi-Fi. Сохранить их сейчас по сотовой сети?": "Photos and videos are only backed up over Wi-Fi. Back them up over cellular now?",
]
}
