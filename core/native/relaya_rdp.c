/* Прослойка relaya-core над FreeRDP 3: подключение, кадры BGRA, ввод, буфер обмена (текст), звук PCM, сертификат.
 * Поток сессии — тот, что вызвал relaya_rdp_run; команды из других потоков идут через очередь и событие wake. */

#include "relaya_rdp.h"

#include <string.h>

#include <winpr/crt.h>
#include <winpr/string.h>
#include <winpr/synch.h>
#include <winpr/user.h>

#include <freerdp/addin.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpsnd.h>
#include <freerdp/event.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>

enum cmd_kind { CMD_KEY, CMD_UNICODE, CMD_POINTER, CMD_BUTTON, CMD_WHEEL, CMD_RESIZE, CMD_CLIPBOARD, CMD_DISCONNECT };

typedef struct cmd
{
	enum cmd_kind kind;
	uint32_t a, b;
	int flag;
	char* text;
	struct cmd* next;
} cmd;

struct relaya_rdp
{
	relaya_rdp_config cfg;
	char* host;
	char* config_path;
	char* user;
	char* password;
	char* domain;
	char* gw_host;
	char* gw_user;
	char* gw_password;
	char* gw_domain;
	relaya_rdp_callbacks cb;

	CRITICAL_SECTION lock;
	HANDLE wake;
	cmd* head;
	cmd* tail;

	rdpContext* context;
	DispClientContext* disp;
	CliprdrClientContext* cliprdr;
	char* local_text;
	int cert_rejected;
	/* Пустой пароль, а сервер требует NLA: второй заход — NLA с пустой строкой вместо «нет учётных данных». */
	int blank_nla;
	int closed;
	uint16_t last_x, last_y;
};

typedef struct
{
	rdpClientContext common;
	relaya_rdp* owner;
} relaya_context;

static char* dup_or_null(const char* s) { return (s && *s) ? _strdup(s) : NULL; }

static void close_once(relaya_rdp* r, int kind, const char* message)
{
	if (r->closed)
		return;
	r->closed = 1;
	if (r->cb.on_closed)
		r->cb.on_closed(r->cb.user, kind, message ? message : "");
}

static relaya_rdp* owner_of(rdpContext* context) { return context ? ((relaya_context*)context)->owner : NULL; }

/* ---------- очередь команд ---------- */

static void push(relaya_rdp* r, enum cmd_kind kind, uint32_t a, uint32_t b, int flag, const char* text)
{
	cmd* c = calloc(1, sizeof(cmd));
	if (!c)
		return;
	c->kind = kind;
	c->a = a;
	c->b = b;
	c->flag = flag;
	c->text = text ? _strdup(text) : NULL;
	EnterCriticalSection(&r->lock);
	if (r->tail)
		r->tail->next = c;
	else
		r->head = c;
	r->tail = c;
	LeaveCriticalSection(&r->lock);
	SetEvent(r->wake);
}

static cmd* take_all(relaya_rdp* r)
{
	EnterCriticalSection(&r->lock);
	cmd* c = r->head;
	r->head = r->tail = NULL;
	ResetEvent(r->wake);
	LeaveCriticalSection(&r->lock);
	return c;
}

/* ---------- буфер обмена ---------- */

static UINT clip_send_format_list(relaya_rdp* r)
{
	if (!r->cliprdr || !r->cliprdr->ClientFormatList)
		return CHANNEL_RC_OK;
	CLIPRDR_FORMAT format = { CF_UNICODETEXT, NULL };
	CLIPRDR_FORMAT_LIST list = { 0 };
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = r->local_text ? 1 : 0;
	list.formats = r->local_text ? &format : NULL;
	return r->cliprdr->ClientFormatList(r->cliprdr, &list);
}

static UINT clip_monitor_ready(CliprdrClientContext* ctx, const CLIPRDR_MONITOR_READY* ready)
{
	WINPR_UNUSED(ready);
	relaya_rdp* r = ctx->custom;
	CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
	CLIPRDR_CAPABILITIES caps = { 0 };
	caps.cCapabilitiesSets = 1;
	caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
	UINT rc = ctx->ClientCapabilities(ctx, &caps);
	if (rc != CHANNEL_RC_OK)
		return rc;
	return clip_send_format_list(r);
}

static UINT clip_server_caps(CliprdrClientContext* ctx, const CLIPRDR_CAPABILITIES* caps)
{
	WINPR_UNUSED(ctx);
	WINPR_UNUSED(caps);
	return CHANNEL_RC_OK;
}

static UINT clip_server_format_list(CliprdrClientContext* ctx, const CLIPRDR_FORMAT_LIST* list)
{
	relaya_rdp* r = ctx->custom;
	CLIPRDR_FORMAT_LIST_RESPONSE resp = { 0 };
	resp.common.msgType = CB_FORMAT_LIST_RESPONSE;
	resp.common.msgFlags = CB_RESPONSE_OK;
	UINT rc = ctx->ClientFormatListResponse(ctx, &resp);
	if (rc != CHANNEL_RC_OK)
		return rc;
	/* Текст на удалённой машине — забрать сразу, если клиент его ждёт. */
	if (!r->cb.on_clipboard)
		return CHANNEL_RC_OK;
	for (UINT32 i = 0; i < list->numFormats; i++)
	{
		if (list->formats[i].formatId == CF_UNICODETEXT)
		{
			CLIPRDR_FORMAT_DATA_REQUEST req = { 0 };
			req.common.msgType = CB_FORMAT_DATA_REQUEST;
			req.requestedFormatId = CF_UNICODETEXT;
			return ctx->ClientFormatDataRequest(ctx, &req);
		}
	}
	return CHANNEL_RC_OK;
}

static UINT clip_server_format_list_response(CliprdrClientContext* ctx, const CLIPRDR_FORMAT_LIST_RESPONSE* resp)
{
	WINPR_UNUSED(ctx);
	WINPR_UNUSED(resp);
	return CHANNEL_RC_OK;
}

static UINT clip_server_data_response(CliprdrClientContext* ctx, const CLIPRDR_FORMAT_DATA_RESPONSE* resp)
{
	relaya_rdp* r = ctx->custom;
	if ((resp->common.msgFlags & CB_RESPONSE_FAIL) || !resp->requestedFormatData || !r->cb.on_clipboard)
		return CHANNEL_RC_OK;
	char* text = ConvertWCharNToUtf8Alloc((const WCHAR*)resp->requestedFormatData, resp->common.dataLen / sizeof(WCHAR), NULL);
	if (text)
	{
		r->cb.on_clipboard(r->cb.user, text);
		free(text);
	}
	return CHANNEL_RC_OK;
}

static UINT clip_server_data_request(CliprdrClientContext* ctx, const CLIPRDR_FORMAT_DATA_REQUEST* req)
{
	relaya_rdp* r = ctx->custom;
	CLIPRDR_FORMAT_DATA_RESPONSE resp = { 0 };
	resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
	WCHAR* wide = NULL;
	size_t chars = 0;
	if (req->requestedFormatId == CF_UNICODETEXT && r->local_text)
		wide = ConvertUtf8ToWCharAlloc(r->local_text, &chars);
	if (wide)
	{
		resp.common.msgFlags = CB_RESPONSE_OK;
		resp.common.dataLen = (UINT32)((chars + 1) * sizeof(WCHAR));
		resp.requestedFormatData = (const BYTE*)wide;
	}
	else
		resp.common.msgFlags = CB_RESPONSE_FAIL;
	UINT rc = ctx->ClientFormatDataResponse(ctx, &resp);
	free(wide);
	return rc;
}

/* ---------- каналы ---------- */

static void on_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	relaya_rdp* r = owner_of(context);
	if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		CliprdrClientContext* clip = e->pInterface;
		clip->custom = r;
		clip->MonitorReady = clip_monitor_ready;
		clip->ServerCapabilities = clip_server_caps;
		clip->ServerFormatList = clip_server_format_list;
		clip->ServerFormatListResponse = clip_server_format_list_response;
		clip->ServerFormatDataResponse = clip_server_data_response;
		clip->ServerFormatDataRequest = clip_server_data_request;
		r->cliprdr = clip;
	}
	else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
		r->disp = e->pInterface;
	else
		freerdp_client_OnChannelConnectedEventHandler(context, e);
}

static void on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	relaya_rdp* r = owner_of(context);
	if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
		r->cliprdr = NULL;
	else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
		r->disp = NULL;
	else
		freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

/* ---------- звук: своё устройство rdpsnd «relaya» ---------- */

typedef struct
{
	rdpsndDevicePlugin device;
	relaya_rdp* owner;
	AUDIO_FORMAT format;
} relaya_snd;

static relaya_rdp* snd_owner(rdpsndDevicePlugin* d)
{
	relaya_snd* s = (relaya_snd*)d;
	if (!s->owner)
		s->owner = owner_of(freerdp_rdpsnd_get_context(d->rdpsnd));
	return s->owner;
}

/* Только PCM 16 бит: сжатые форматы не принимаем, сервер выберет PCM. */
static BOOL snd_supported(rdpsndDevicePlugin* d, const AUDIO_FORMAT* f)
{
	WINPR_UNUSED(d);
	return f->wFormatTag == WAVE_FORMAT_PCM && f->wBitsPerSample == 16 && f->nChannels >= 1 && f->nChannels <= 2;
}

static BOOL snd_open(rdpsndDevicePlugin* d, const AUDIO_FORMAT* f, UINT32 latency)
{
	WINPR_UNUSED(latency);
	((relaya_snd*)d)->format = *f;
	return TRUE;
}

static UINT32 snd_get_volume(rdpsndDevicePlugin* d)
{
	WINPR_UNUSED(d);
	return 0xFFFFFFFF;
}

static BOOL snd_set_volume(rdpsndDevicePlugin* d, UINT32 value)
{
	relaya_rdp* r = snd_owner(d);
	if (r && r->cb.on_audio_volume)
		r->cb.on_audio_volume(r->cb.user, (uint16_t)(value & 0xFFFF), (uint16_t)(value >> 16));
	return TRUE;
}

static UINT snd_play(rdpsndDevicePlugin* d, const BYTE* data, size_t size)
{
	relaya_snd* s = (relaya_snd*)d;
	relaya_rdp* r = snd_owner(d);
	if (r && r->cb.on_audio)
		r->cb.on_audio(r->cb.user, s->format.nSamplesPerSec, s->format.nChannels, s->format.wBitsPerSample, 0, data, size);
	return 0; /* задержка воспроизведения, мс: играет клиент */
}

static void snd_close(rdpsndDevicePlugin* d)
{
	relaya_rdp* r = snd_owner(d);
	if (r && r->cb.on_audio_closed)
		r->cb.on_audio_closed(r->cb.user);
}

static void snd_free(rdpsndDevicePlugin* d) { free(d); }

static UINT VCAPITYPE relaya_rdpsnd_entry(PFREERDP_RDPSND_DEVICE_ENTRY_POINTS ep)
{
	relaya_snd* s = calloc(1, sizeof(relaya_snd));
	if (!s)
		return CHANNEL_RC_NO_MEMORY;
	s->device.FormatSupported = snd_supported;
	s->device.Open = snd_open;
	s->device.GetVolume = snd_get_volume;
	s->device.SetVolume = snd_set_volume;
	s->device.Play = snd_play;
	s->device.Close = snd_close;
	s->device.Free = snd_free;
	ep->pRegisterRdpsndDevice(ep->rdpsnd, &s->device);
	return CHANNEL_RC_OK;
}

static FREERDP_LOAD_CHANNEL_ADDIN_ENTRY_FN previous_provider = NULL;

static PVIRTUALCHANNELENTRY relaya_addin_provider(LPCSTR name, LPCSTR subsystem, LPCSTR type, DWORD flags)
{
	if (name && subsystem && strcmp(name, "rdpsnd") == 0 && strcmp(subsystem, "relaya") == 0)
		return (PVIRTUALCHANNELENTRY)(void*)relaya_rdpsnd_entry;
	return previous_provider ? previous_provider(name, subsystem, type, flags) : NULL;
}

/* ---------- графика ---------- */

static BOOL begin_paint(rdpContext* context)
{
	context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
	context->gdi->primary->hdc->hwnd->ninvalid = 0;
	return TRUE;
}

static BOOL end_paint(rdpContext* context)
{
	relaya_rdp* r = owner_of(context);
	rdpGdi* gdi = context->gdi;
	HGDI_WND hwnd = gdi->primary->hdc->hwnd;
	if (hwnd->invalid->null || hwnd->ninvalid <= 0)
		return TRUE;
	for (INT32 i = 0; i < hwnd->ninvalid; i++)
	{
		const GDI_RGN* rgn = &hwnd->cinvalid[i];
		INT32 x = rgn->x < 0 ? 0 : rgn->x, y = rgn->y < 0 ? 0 : rgn->y;
		INT32 w = rgn->w, h = rgn->h;
		if (x + w > gdi->width) w = gdi->width - x;
		if (y + h > gdi->height) h = gdi->height - y;
		if (w > 0 && h > 0 && r->cb.on_rect)
			r->cb.on_rect(r->cb.user, gdi->primary_buffer, (size_t)gdi->stride * (size_t)gdi->height, gdi->stride, (uint32_t)x, (uint32_t)y, (uint32_t)w, (uint32_t)h);
	}
	if (r->cb.on_frame_end)
		r->cb.on_frame_end(r->cb.user);
	return TRUE;
}

static BOOL desktop_resize(rdpContext* context)
{
	relaya_rdp* r = owner_of(context);
	rdpSettings* s = context->settings;
	UINT32 w = freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth), h = freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight);
	if (!gdi_resize(context->gdi, w, h))
		return FALSE;
	if (r->cb.on_resize)
		r->cb.on_resize(r->cb.user, w, h);
	if (r->cb.on_rect)
		r->cb.on_rect(r->cb.user, context->gdi->primary_buffer, (size_t)context->gdi->stride * h, context->gdi->stride, 0, 0, w, h);
	if (r->cb.on_frame_end)
		r->cb.on_frame_end(r->cb.user);
	return TRUE;
}

/* ---------- подключение ---------- */

static BOOL pre_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	if (PubSub_SubscribeChannelConnected(context->pubSub, on_channel_connected) < 0)
		return FALSE;
	if (PubSub_SubscribeChannelDisconnected(context->pubSub, on_channel_disconnected) < 0)
		return FALSE;
	return TRUE;
}

static BOOL post_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	relaya_rdp* r = owner_of(context);
	if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
		return FALSE;
	context->update->BeginPaint = begin_paint;
	context->update->EndPaint = end_paint;
	context->update->DesktopResize = desktop_resize;
	rdpGdi* gdi = context->gdi;
	if (r->cb.on_connected)
		r->cb.on_connected(r->cb.user, (uint32_t)gdi->width, (uint32_t)gdi->height);
	if (r->cb.on_rect)
		r->cb.on_rect(r->cb.user, gdi->primary_buffer, (size_t)gdi->stride * (size_t)gdi->height, gdi->stride, 0, 0, (uint32_t)gdi->width, (uint32_t)gdi->height);
	if (r->cb.on_frame_end)
		r->cb.on_frame_end(r->cb.user);
	return TRUE;
}

static void post_disconnect(freerdp* instance)
{
	rdpContext* context = instance->context;
	PubSub_UnsubscribeChannelConnected(context->pubSub, on_channel_connected);
	PubSub_UnsubscribeChannelDisconnected(context->pubSub, on_channel_disconnected);
	gdi_free(instance);
}

/* Отпечаток FreeRDP — «aa:bb:…»; ядру нужен hex без разделителей в нижнем регистре. */
static void normalize_fp(const char* in, char* out, size_t cap)
{
	size_t n = 0;
	for (; in && *in && n + 1 < cap; in++)
	{
		char c = *in;
		if (c == ':')
			continue;
		out[n++] = (c >= 'A' && c <= 'F') ? (char)(c - 'A' + 'a') : c;
	}
	out[n] = 0;
}

static DWORD verify_cert(freerdp* instance, const char* host, UINT16 port, const char* common_name, const char* subject,
                         const char* issuer, const char* fingerprint, DWORD flags)
{
	WINPR_UNUSED(host);
	WINPR_UNUSED(port);
	WINPR_UNUSED(common_name);
	WINPR_UNUSED(issuer);
	WINPR_UNUSED(flags);
	relaya_rdp* r = owner_of(instance->context);
	char fp[160];
	normalize_fp(fingerprint, fp, sizeof(fp));
	int ok = r->cb.on_cert ? r->cb.on_cert(r->cb.user, fp, subject ? subject : "") : 0;
	if (!ok)
		r->cert_rejected = 1;
	return ok ? 2 : 0; /* 2 — только на эту сессию: доверие хранит Relaya, не FreeRDP */
}

static DWORD verify_changed_cert(freerdp* instance, const char* host, UINT16 port, const char* common_name,
                                 const char* subject, const char* issuer, const char* new_fp, const char* old_subject,
                                 const char* old_issuer, const char* old_fp, DWORD flags)
{
	WINPR_UNUSED(old_subject);
	WINPR_UNUSED(old_issuer);
	WINPR_UNUSED(old_fp);
	return verify_cert(instance, host, port, common_name, subject, issuer, new_fp, flags);
}

/* Учётные данные уже в настройках; ничего не спрашиваем в консоли. */
static BOOL authenticate(freerdp* instance, char** username, char** password, char** domain, rdp_auth_reason reason)
{
	WINPR_UNUSED(instance);
	WINPR_UNUSED(username);
	WINPR_UNUSED(password);
	WINPR_UNUSED(domain);
	WINPR_UNUSED(reason);
	return TRUE;
}

static BOOL client_new(freerdp* instance, rdpContext* context)
{
	WINPR_UNUSED(context);
	instance->PreConnect = pre_connect;
	instance->PostConnect = post_connect;
	instance->PostDisconnect = post_disconnect;
	instance->VerifyCertificateEx = verify_cert;
	instance->VerifyChangedCertificateEx = verify_changed_cert;
	instance->AuthenticateEx = authenticate;
	return TRUE;
}

static void client_free(freerdp* instance, rdpContext* context)
{
	WINPR_UNUSED(instance);
	WINPR_UNUSED(context);
}

static int client_start(rdpContext* context)
{
	WINPR_UNUSED(context);
	return 0;
}

static int client_stop(rdpContext* context)
{
	WINPR_UNUSED(context);
	return 0;
}

static BOOL apply_settings(relaya_rdp* r, rdpSettings* s)
{
	BOOL ok = TRUE;
	/* Свой пустой каталог: хранилище FreeRDP не пишет ~/.config/freerdp и не решает за verify_cert («host key changed»). */
	if (r->config_path)
		ok &= freerdp_settings_set_string(s, FreeRDP_ConfigPath, r->config_path);
	ok &= freerdp_settings_set_string(s, FreeRDP_ServerHostname, r->host);
	ok &= freerdp_settings_set_uint32(s, FreeRDP_ServerPort, r->cfg.port ? r->cfg.port : 3389);
	ok &= freerdp_settings_set_string(s, FreeRDP_Username, r->user);
	ok &= freerdp_settings_set_string(s, FreeRDP_Password, r->password);
	/* Пустой пароль: NLA без учётных данных не пройдёт (LimitBlankPasswordUse), вход — на экране сервера, как у mstsc.
	   Остаётся только TLS: у него есть сертификат, и verify_cert (TOFU) спрашивается; старая RDP Security без
	   сертификата выключена, чтобы подмену сервера нельзя было пропустить молча. Непустой пароль всегда идёт через NLA:
	   автоповтора без NLA нет — иначе пароль ушёл бы серверу в обход CredSSP (решение аудита безопасности). */
	const BOOL no_password = !r->password || !r->password[0];
	/* Учётная запись без пароля на сервере, где NLA обязателен (ERRCONNECT_HYBRID_REQUIRED_BY_SERVER): FreeRDP
	   считает NULL-пароль отсутствием учётных данных, поэтому передаём пустую строку — CredSSP с пустым паролем,
	   как у mstsc и прежнего RDPKit. Секрета нет, обхода CredSSP нет. */
	if (no_password && r->blank_nla)
		ok &= freerdp_settings_set_string(s, FreeRDP_Password, "");
	else if (no_password)
	{
		ok &= freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, FALSE);
		/* HYBRID_EX — тоже CredSSP; без этого nego просит [SSL|HYBRID|HYBRID_EX] и сервер выбирает NLA. */
		ok &= freerdp_settings_set_bool(s, FreeRDP_ExtSecurity, FALSE);
		ok &= freerdp_settings_set_bool(s, FreeRDP_RdstlsSecurity, FALSE);
		ok &= freerdp_settings_set_bool(s, FreeRDP_AadSecurity, FALSE);
		ok &= freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE);
		ok &= freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
	}
	if (r->domain)
		ok &= freerdp_settings_set_string(s, FreeRDP_Domain, r->domain);
	ok &= freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, r->cfg.width < 200 ? 200 : r->cfg.width);
	ok &= freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, r->cfg.height < 200 ? 200 : r->cfg.height);
	if (r->cfg.scale_percent > 100)
		ok &= freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, r->cfg.scale_percent);
	ok &= freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE);
	ok &= freerdp_settings_set_bool(s, FreeRDP_GfxH264, r->cfg.h264 ? TRUE : FALSE);
	ok &= freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, r->cfg.h264 ? TRUE : FALSE);
	ok &= freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE);
	ok &= freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
	ok &= freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE);
	ok &= freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, TRUE);
	ok &= freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, r->cfg.audio ? TRUE : FALSE);
	if (r->cfg.audio)
	{
		const char* params[] = { "rdpsnd", "sys:relaya" };
		ok &= freerdp_client_add_static_channel(s, ARRAYSIZE(params), params);
	}
	if (r->gw_host)
	{
		/* host, host:port, [IPv6] или [IPv6]:port; голый IPv6 (несколько двоеточий) — целиком адрес. */
		UINT32 gw_port = 443;
		char* host = r->gw_host;
		if (host[0] == '[')
		{
			char* close = strchr(host, ']');
			if (close)
			{
				*close = 0;
				if (close[1] == ':')
					gw_port = (UINT32)strtoul(close + 2, NULL, 10);
				memmove(host, host + 1, strlen(host + 1) + 1);
			}
		}
		else
		{
			char* colon = strchr(host, ':');
			if (colon && colon == strrchr(host, ':'))
			{
				*colon = 0;
				gw_port = (UINT32)strtoul(colon + 1, NULL, 10);
			}
		}
		ok &= freerdp_settings_set_string(s, FreeRDP_GatewayHostname, r->gw_host);
		ok &= freerdp_settings_set_uint32(s, FreeRDP_GatewayPort, gw_port ? gw_port : 443);
		ok &= freerdp_settings_set_bool(s, FreeRDP_GatewayEnabled, TRUE);
		ok &= freerdp_settings_set_uint32(s, FreeRDP_GatewayUsageMethod, TSC_PROXY_MODE_DIRECT);
		BOOL same = r->gw_user == NULL;
		ok &= freerdp_settings_set_bool(s, FreeRDP_GatewayUseSameCredentials, same);
		if (!same)
		{
			ok &= freerdp_settings_set_string(s, FreeRDP_GatewayUsername, r->gw_user);
			ok &= freerdp_settings_set_string(s, FreeRDP_GatewayPassword, r->gw_password ? r->gw_password : "");
			if (r->gw_domain)
				ok &= freerdp_settings_set_string(s, FreeRDP_GatewayDomain, r->gw_domain);
		}
	}
	return ok;
}

relaya_rdp* relaya_rdp_new(const relaya_rdp_config* config, const relaya_rdp_callbacks* callbacks)
{
	relaya_rdp* r = calloc(1, sizeof(relaya_rdp));
	if (!r)
		return NULL;
	r->cfg = *config;
	r->host = dup_or_null(config->host);
	r->config_path = dup_or_null(config->config_path);
	r->user = dup_or_null(config->user);
	r->password = dup_or_null(config->password);
	r->domain = dup_or_null(config->domain);
	r->gw_host = dup_or_null(config->gateway_host);
	r->gw_user = dup_or_null(config->gateway_user);
	r->gw_password = dup_or_null(config->gateway_password);
	r->gw_domain = dup_or_null(config->gateway_domain);
	r->cb = *callbacks;
	InitializeCriticalSection(&r->lock);
	r->wake = CreateEventA(NULL, TRUE, FALSE, NULL);
	return r;
}

static int close_kind(UINT32 error, int cert_rejected)
{
	if (cert_rejected)
		return RELAYA_CLOSE_CERT;
	switch (error)
	{
		case FREERDP_ERROR_SUCCESS:
			return RELAYA_CLOSE_USER;
		case FREERDP_ERROR_AUTHENTICATION_FAILED:
		case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
		case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
		case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
		case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
			return RELAYA_CLOSE_AUTH;
		case FREERDP_ERROR_DNS_ERROR:
		case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
		case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
			return RELAYA_CLOSE_NETWORK;
		default:
			return RELAYA_CLOSE_PROTOCOL;
	}
}

static void run_commands(relaya_rdp* r, freerdp* instance)
{
	rdpInput* input = instance->context->input;
	for (cmd* c = take_all(r); c;)
	{
		switch (c->kind)
		{
			case CMD_KEY:
				freerdp_input_send_keyboard_event_ex(input, c->flag, FALSE,
				                                     (c->a & 0xE000) == 0xE000 ? (0x100 | (c->a & 0xFF)) : (c->a & 0xFF));
				break;
			case CMD_UNICODE:
				freerdp_input_send_unicode_keyboard_event(input, c->flag ? 0 : KBD_FLAGS_RELEASE, (UINT16)c->a);
				break;
			case CMD_POINTER:
				r->last_x = (uint16_t)c->a;
				r->last_y = (uint16_t)c->b;
				freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, r->last_x, r->last_y);
				break;
			case CMD_BUTTON:
			{
				UINT16 down = c->flag ? PTR_FLAGS_DOWN : 0;
				switch (c->a)
				{
					case 0: freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON1 | down, r->last_x, r->last_y); break;
					case 1: freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON3 | down, r->last_x, r->last_y); break;
					case 2: freerdp_input_send_mouse_event(input, PTR_FLAGS_BUTTON2 | down, r->last_x, r->last_y); break;
					case 3: freerdp_input_send_extended_mouse_event(input, PTR_XFLAGS_BUTTON1 | (c->flag ? PTR_XFLAGS_DOWN : 0), r->last_x, r->last_y); break;
					case 4: freerdp_input_send_extended_mouse_event(input, PTR_XFLAGS_BUTTON2 | (c->flag ? PTR_XFLAGS_DOWN : 0), r->last_x, r->last_y); break;
					default: break;
				}
				break;
			}
			case CMD_WHEEL:
			{
				INT32 units = (INT16)c->a;
				UINT16 flags = c->flag ? PTR_FLAGS_WHEEL : PTR_FLAGS_HWHEEL;
				if (units < 0)
				{
					flags |= PTR_FLAGS_WHEEL_NEGATIVE;
					units = 0x100 + units; /* 9-битное дополнение до двух */
				}
				freerdp_input_send_mouse_event(input, (UINT16)(flags | (units & 0xFF)), r->last_x, r->last_y);
				break;
			}
			case CMD_RESIZE:
				if (r->disp && r->disp->SendMonitorLayout)
				{
					DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
					layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
					layout.Width = c->a < 200 ? 200 : (c->a > 8192 ? 8192 : c->a) & ~1u;
					layout.Height = c->b < 200 ? 200 : (c->b > 8192 ? 8192 : c->b);
					layout.DesktopScaleFactor = r->cfg.scale_percent > 100 ? r->cfg.scale_percent : 100;
					layout.DeviceScaleFactor = 100;
					(void)r->disp->SendMonitorLayout(r->disp, 1, &layout);
				}
				break;
			case CMD_CLIPBOARD:
				free(r->local_text);
				r->local_text = c->text;
				c->text = NULL;
				(void)clip_send_format_list(r);
				break;
			case CMD_DISCONNECT:
				freerdp_abort_connect_context(instance->context);
				break;
		}
		cmd* next = c->next;
		free(c->text);
		free(c);
		c = next;
	}
}

void relaya_rdp_run(relaya_rdp* r)
{
	if (!previous_provider)
	{
		previous_provider = freerdp_get_current_addin_provider();
		(void)freerdp_register_addin_provider(relaya_addin_provider, 0);
	}
	RDP_CLIENT_ENTRY_POINTS ep = { 0 };
	ep.Version = RDP_CLIENT_INTERFACE_VERSION;
	ep.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	ep.ContextSize = sizeof(relaya_context);
	ep.ClientNew = client_new;
	ep.ClientFree = client_free;
	ep.ClientStart = client_start;
	ep.ClientStop = client_stop;
	for (int attempt = 0;; attempt++)
	{
	rdpContext* context = freerdp_client_context_new(&ep);
	if (!context)
	{
		close_once(r, RELAYA_CLOSE_PROTOCOL, "freerdp_client_context_new failed");
		return;
	}
	((relaya_context*)context)->owner = r;
	r->context = context;
	freerdp* instance = context->instance;
	if (!apply_settings(r, context->settings) || freerdp_client_start(context) != 0)
	{
		close_once(r, RELAYA_CLOSE_PROTOCOL, "settings");
		freerdp_client_context_free(context);
		return;
	}

	if (!freerdp_connect(instance))
	{
		UINT32 e = freerdp_get_last_error(context);
		/* Сервер требует NLA, а пароля нет — один повтор с NLA и пустым паролем (см. apply_settings). */
		if (attempt == 0 && (!r->password || !r->password[0]) && !r->blank_nla && !r->cert_rejected &&
		    strcmp(freerdp_get_last_error_name(e), "ERRCONNECT_HYBRID_REQUIRED_BY_SERVER") == 0)
		{
			r->blank_nla = 1;
			freerdp_client_stop(context);
			r->context = NULL;
			freerdp_client_context_free(context);
			continue;
		}
		char msg[512];
		_snprintf(msg, sizeof(msg), "%s: %s", freerdp_get_last_error_name(e), freerdp_get_last_error_string(e));
		msg[sizeof(msg) - 1] = 0; /* _snprintf не ставит '\0' при усечении */
		close_once(r, close_kind(e, r->cert_rejected), msg);
	}
	else
	{
		while (!freerdp_shall_disconnect_context(context))
		{
			HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
			DWORD n = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles) - 1);
			if (n == 0)
				break;
			handles[n++] = r->wake;
			if (WaitForMultipleObjects(n, handles, FALSE, 100) == WAIT_FAILED)
				break;
			run_commands(r, instance);
			if (!freerdp_check_event_handles(context))
				break;
		}
		UINT32 e = freerdp_get_last_error(context);
		char msg[512];
		_snprintf(msg, sizeof(msg), "%s: %s", freerdp_get_last_error_name(e), freerdp_get_last_error_string(e));
		msg[sizeof(msg) - 1] = 0; /* _snprintf не ставит '\0' при усечении */
		close_once(r, e == FREERDP_ERROR_SUCCESS ? RELAYA_CLOSE_USER : RELAYA_CLOSE_SERVER, msg);
		freerdp_disconnect(instance);
	}
	freerdp_client_stop(context);
	r->context = NULL;
	freerdp_client_context_free(context);
	return;
	}
}

void relaya_rdp_free(relaya_rdp* r)
{
	if (!r)
		return;
	for (cmd* c = take_all(r); c;)
	{
		cmd* next = c->next;
		free(c->text);
		free(c);
		c = next;
	}
	CloseHandle(r->wake);
	DeleteCriticalSection(&r->lock);
	free(r->host);
	free(r->config_path);
	free(r->user);
	free(r->password);
	free(r->domain);
	free(r->gw_host);
	free(r->gw_user);
	free(r->gw_password);
	free(r->gw_domain);
	free(r->local_text);
	free(r);
}

void relaya_rdp_key(relaya_rdp* r, uint16_t scancode, int down) { push(r, CMD_KEY, scancode, 0, down, NULL); }
void relaya_rdp_unicode(relaya_rdp* r, uint16_t code, int down) { push(r, CMD_UNICODE, code, 0, down, NULL); }
void relaya_rdp_pointer(relaya_rdp* r, uint16_t x, uint16_t y) { push(r, CMD_POINTER, x, y, 0, NULL); }
void relaya_rdp_button(relaya_rdp* r, uint8_t button, int down) { push(r, CMD_BUTTON, button, 0, down, NULL); }
void relaya_rdp_wheel(relaya_rdp* r, int16_t units, int vertical) { push(r, CMD_WHEEL, (uint32_t)(uint16_t)units, 0, vertical, NULL); }
void relaya_rdp_resize(relaya_rdp* r, uint32_t width, uint32_t height) { push(r, CMD_RESIZE, width, height, 0, NULL); }
void relaya_rdp_set_clipboard(relaya_rdp* r, const char* utf8) { push(r, CMD_CLIPBOARD, 0, 0, 0, utf8 ? utf8 : ""); }
void relaya_rdp_disconnect(relaya_rdp* r) { push(r, CMD_DISCONNECT, 0, 0, 0, NULL); }
