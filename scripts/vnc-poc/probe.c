/* Проверка RoyalVNCKit через C API (vnc-poc.yml): подключиться, войти по паролю из VNC_PASSWORD,
 * дождаться кадра с ненулевыми пикселями; с EXPECT_RESIZE=1 — ещё смены размера (ExtendedDesktopSize)
 * и нового ненулевого кадра после неё. Код выхода 0 — успех, 1 — ошибка или таймаут 60 с. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef _WIN32
#include <windows.h>
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <unistd.h>
static void sleep_ms(int ms) { usleep(ms * 1000); }
#endif
#include "RoyalVNCKitC.h"

static volatile int first_frame = 0, resized = 0, frame_after_resize = 0, failed = 0;
static volatile uint16_t width = 0, height = 0;

static bool has_pixels(rvnc_framebuffer_t fb)
{
	const uint8_t* p = rvnc_framebuffer_pixel_data_get(fb);
	uint64_t n = rvnc_framebuffer_pixel_data_size_get(fb);
	for (uint64_t i = 0; i + 3 < n; i += 4)
		if (p[i] | p[i + 1] | p[i + 2])
			return true;
	return false;
}

static void on_log(rvnc_logger_t l, const rvnc_context_t c, RVNC_LOG_LEVEL level, const char* msg)
{
	(void)l; (void)c;
	if (level >= RVNC_LOG_LEVEL_WARNING) printf("LOG %d %s\n", level, msg);
}

static void on_state(rvnc_connection_t conn, const rvnc_context_t c, rvnc_connection_state_t st)
{
	(void)conn; (void)c;
	RVNC_CONNECTION_STATUS s = rvnc_connection_state_status_get(st);
	char* err = rvnc_connection_state_error_description_get_copy(st);
	printf("STATE %d %s\n", (int)s, err ? err : "");
	if (s == RVNC_CONNECTION_STATUS_DISCONNECTED && err) failed = 1;
	free(err);
	fflush(stdout);
}

static void on_auth(rvnc_connection_t conn, const rvnc_context_t c, rvnc_authentication_request_t req)
{
	(void)conn; (void)c;
	const char* pw = getenv("VNC_PASSWORD");
	RVNC_AUTHENTICATIONTYPE t = rvnc_authentication_request_authentication_type_get(req);
	printf("AUTH type=%d\n", (int)t);
	if (!pw) { rvnc_authentication_request_cancel(req); return; }
	if (rvnc_authentication_type_requires_username(t))
		rvnc_authentication_request_complete_with_username_password(req, getenv("VNC_USER") ? getenv("VNC_USER") : "", pw);
	else
		rvnc_authentication_request_complete_with_password(req, pw);
}

static void on_create(rvnc_connection_t conn, const rvnc_context_t c, rvnc_framebuffer_t fb)
{
	(void)conn; (void)c;
	width = rvnc_framebuffer_size_width_get(fb);
	height = rvnc_framebuffer_size_height_get(fb);
	printf("CREATE %ux%u\n", width, height);
	fflush(stdout);
}

static void on_resize(rvnc_connection_t conn, const rvnc_context_t c, rvnc_framebuffer_t fb)
{
	(void)conn; (void)c;
	uint16_t w = rvnc_framebuffer_size_width_get(fb), h = rvnc_framebuffer_size_height_get(fb);
	printf("RESIZED %ux%u (was %ux%u)\n", w, h, width, height);
	width = w; height = h;
	resized = 1;
	fflush(stdout);
}

static void on_update(rvnc_connection_t conn, const rvnc_context_t c, rvnc_framebuffer_t fb, uint16_t x, uint16_t y, uint16_t w, uint16_t h)
{
	(void)conn; (void)c;
	if (!has_pixels(fb)) return;
	if (!first_frame) { first_frame = 1; printf("FIRST_FRAME %ux%u rect %u,%u %ux%u\n", width, height, x, y, w, h); }
	else if (resized && !frame_after_resize) { frame_after_resize = 1; printf("FRAME_AFTER_RESIZE %ux%u\n", width, height); }
	fflush(stdout);
}

static void on_cursor(rvnc_connection_t conn, const rvnc_context_t c, rvnc_cursor_t cur) { (void)conn; (void)c; (void)cur; }

int main(int argc, char** argv)
{
	if (argc < 3) { fprintf(stderr, "usage: probe host port\n"); return 2; }
	bool expect_resize = getenv("EXPECT_RESIZE") && strcmp(getenv("EXPECT_RESIZE"), "1") == 0;
	rvnc_logger_t logger = rvnc_logger_create(on_log, NULL);
	rvnc_settings_t settings = rvnc_settings_create(false, argv[1], (uint16_t)atoi(argv[2]), true, false, false,
	                                                RVNC_INPUTMODE_NONE, false, RVNC_COLORDEPTH_24BIT, NULL);
	rvnc_connection_t conn = rvnc_connection_create(settings, logger, NULL, NULL);
	rvnc_connection_delegate_t d = rvnc_connection_delegate_create(on_state, on_auth, on_create, on_resize, on_update, on_cursor);
	rvnc_connection_delegate_set(conn, d);
	rvnc_connection_connect(conn);
	int rc = 1;
	for (int i = 0; i < 600 && !failed; i++)
	{
		if (first_frame && (!expect_resize || frame_after_resize)) { rc = 0; break; }
		sleep_ms(100);
	}
	printf(rc == 0 ? "PROBE OK\n" : "PROBE FAILED\n");
	fflush(stdout);
	rvnc_connection_disconnect(conn);
	sleep_ms(500);
	return rc; /* ресурсы освобождает завершение процесса */
}
