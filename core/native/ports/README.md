# Overlay-порты vcpkg для relaya-core

`freerdp/` — штатный порт vcpkg с закреплённого baseline (`core/native/vcpkg.json`, коммит
9a5dfef5d1a0438a7d24856a85bd60f309d355e9) плюс правки Relaya:

- `relaya-openh264-path.patch` — FreeRDP загружает OpenH264 по пути из `RELAYA_OPENH264_LIBRARY` (проверенная
  копия `openh264::checked_copy` из ядра), а не по фиксированным именам;
- в `portfile.cmake` на macOS и Linux включены `WITH_OPENH264` и `WITH_OPENH264_LOADING` (заголовки —
  `core/native/openh264/include`, BSD, Cisco 2.6.0). На Windows H.264 — Media Foundation.

Обновление FreeRDP: взять порт из нового baseline и перенести эти две правки.
