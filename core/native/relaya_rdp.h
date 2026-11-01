/* Тонкая прослойка над FreeRDP 3 для relaya-core (feature rdp-freerdp). Ядро на Rust вызывает только эти функции. */
#ifndef RELAYA_RDP_H
#define RELAYA_RDP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct relaya_rdp relaya_rdp;

typedef struct
{
	const char* host;
	uint16_t port;
	const char* user;
	const char* password;
	const char* domain;          /* NULL — без домена */
	uint32_t width;
	uint32_t height;
	uint32_t scale_percent;      /* 100 — без масштаба */
	const char* gateway_host;    /* NULL — напрямую; "host" или "host:port" */
	const char* gateway_user;    /* NULL — те же учётные данные */
	const char* gateway_password;
	const char* gateway_domain;
	int audio;                   /* 1 — просить звук у сервера */
	int h264;                    /* 1 — H.264 (AVC420/444) в графическом конвейере */
	const char* config_path;     /* NULL — по умолчанию; каталог для хранилища сертификатов FreeRDP */
} relaya_rdp_config;

enum relaya_rdp_close
{
	RELAYA_CLOSE_USER = 0,
	RELAYA_CLOSE_AUTH = 1,
	RELAYA_CLOSE_NETWORK = 2,
	RELAYA_CLOSE_SERVER = 3,
	RELAYA_CLOSE_CERT = 4,
	RELAYA_CLOSE_PROTOCOL = 5,
	/* Нужны логин и пароль: сервер требует NLA или имени нет — клиент открывает форму входа. */
	RELAYA_CLOSE_CREDENTIALS = 6,
	/* Пароль верный, но учётная запись не пускает: заблокирована, отключена, пароль истёк — пароль не стирать. */
	RELAYA_CLOSE_ACCOUNT = 7
};

/* Все колбэки — из потока relaya_rdp_run. */
typedef struct
{
	void* user;
	void (*on_connected)(void* user, uint32_t width, uint32_t height);
	/* Изменившийся прямоугольник: буфер BGRA всего экрана и его stride; после последнего — on_frame_end. */
	/* len — размер буфера в байтах: прямоугольник проверяется по нему. */
	void (*on_rect)(void* user, const uint8_t* buffer, size_t len, uint32_t stride, uint32_t x, uint32_t y, uint32_t w, uint32_t h);
	void (*on_frame_end)(void* user);
	void (*on_resize)(void* user, uint32_t width, uint32_t height);
	/* sha256 сертификата (hex без двоеточий) и subject; вернуть 1 — принять, 0 — отказ. Может ждать ответа UI. */
	/* host/port — узел, чей сертификат проверяется (R-4); gateway — это RD Gateway (VERIFY_CERT_FLAG_GATEWAY). */
	int (*on_cert)(void* user, const char* sha256, const char* subject, const char* host, uint16_t port, int gateway);
	/* NULL — обмен буфером выключен: текст с сервера не запрашивается. */
	void (*on_clipboard)(void* user, const char* utf8);
	void (*on_audio)(void* user, uint32_t rate, uint16_t channels, uint16_t bits, uint32_t timestamp, const uint8_t* pcm,
	                 size_t size);
	void (*on_audio_volume)(void* user, uint16_t left, uint16_t right);
	void (*on_audio_closed)(void* user);
	void (*on_closed)(void* user, int kind, const char* message);
} relaya_rdp_callbacks;

relaya_rdp* relaya_rdp_new(const relaya_rdp_config* config, const relaya_rdp_callbacks* callbacks);
/* Подключиться и крутить сессию до отключения; on_closed вызывается ровно один раз. */
void relaya_rdp_run(relaya_rdp* rdp);
void relaya_rdp_free(relaya_rdp* rdp);

/* Из любого потока: команды ставятся в очередь и уходят из потока сессии. */
void relaya_rdp_key(relaya_rdp* rdp, uint16_t scancode, int down);
void relaya_rdp_unicode(relaya_rdp* rdp, uint16_t code, int down);
void relaya_rdp_pointer(relaya_rdp* rdp, uint16_t x, uint16_t y);
void relaya_rdp_button(relaya_rdp* rdp, uint8_t button, int down);
void relaya_rdp_wheel(relaya_rdp* rdp, int16_t units, int vertical);
void relaya_rdp_resize(relaya_rdp* rdp, uint32_t width, uint32_t height);
void relaya_rdp_set_clipboard(relaya_rdp* rdp, const char* utf8);
void relaya_rdp_disconnect(relaya_rdp* rdp);

#ifdef __cplusplus
}
#endif

#endif
