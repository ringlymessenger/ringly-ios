platform :ios, '15.0'

use_frameworks!

ENV['LIBSIGNAL_FFI_PREBUILD_CHECKSUM'] = 'd43c01e3e76d48de8070dc750f084cd1f2e78787cf6e88fcf4b5dfea2efb9af1'

# общий крипто-слой нужен и приложению, и расширению (NSE расшифровывает баннер)
def signal_pods
  pod 'LibSignalClient', git: 'https://github.com/signalapp/libsignal.git', tag: 'v0.96.2'
  pod 'GRDB.swift/SQLCipher'
end

target 'ringly app' do
  signal_pods
  # Firebase убран: бэкенд шлёт пуши напрямую через APNs, клиент регистрирует сырой APNs device token.
  # Unity LevelPlay (ironSource) — rewarded-реклама за Rings, только основной таргет, НЕ в NSE.
  # Версия — закреплённая, из официальной доки. (AppLovin не принял аккаунт издателя, октябрь 2026.)
  pod 'IronSourceSDK', '9.5.0.0'
  # Unity Ads через медиацию LevelPlay: собственная реклама ironSource закрыта с 30.04.2026, без
  # второй сети медиация отвечала «No fill» даже на тестовую. Адаптер сам тянет UnityAds (= 4.19.0);
  # сеть включается в дашборде LevelPlay (Networks + Instances), код контроллера не меняется.
  pod 'IronSourceUnityAdsAdapter', '5.9.0.0'
end

target 'NotificationService' do
  signal_pods                # NSE: SQLCipher + libsignal для локальной расшифровки
end

# Xcode 27 поднял минимальную поддерживаемую цель до iOS 15.0, и это ОШИБКА сборки, а не
# предупреждение, как раньше. Часть подов до сих пор объявляет в podspec 11.0/12.0 (GRDB, SQLCipher,
# IronSourceSDK) — `platform :ios, '15.0'` выше их не поднимает: CocoaPods берёт значение из podspec,
# если оно задано явно. Поднимаем сами, иначе проект не собирается ни на симулятор, ни на устройство.
#
# ⚠️ Поднимаем, а не ЗАДАЁМ: под, которому нужна цель ВЫШЕ 15.0, опускать нельзя — он завязан
# на API, которых в 15.0 нет. Поэтому сравнение, а не безусловное присваивание.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      current = config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'].to_f
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0' if current < 15.0
    end
  end
end
