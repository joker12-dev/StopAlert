package com.originstudios.stopalert

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * StopAlert ana ekran widget'ı (4x2).
 *
 * İki durumu var:
 *  - Alarm yok  : "Aktif alarm yok" + "Alarm kur" düğmesi
 *  - Alarm var  : kalan durak halkası, kalan mesafe, şu anki + sonraki durak
 *
 * Veriyi Flutter tarafı `home_widget` ile SharedPreferences'a yazar
 * (bkz. HomeWidgetService). Uygulama kapalıyken de son yazılan değer görünür.
 *
 * Halka RemoteViews ile çizilemediği için Canvas'ta bitmap olarak üretilip
 * ImageView'a basılır — böylece ön plan servisi Flutter motoru olmadan da
 * widget'ı tazeleyebilir.
 */
class StopAlertWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { id ->
            val views = RemoteViews(context.packageName, R.layout.widget_stopalert)
            val active = widgetData.getBoolean("active", false)

            if (active) {
                bindActive(context, views, widgetData)
            } else {
                bindIdle(context, views, widgetData)
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private fun bindIdle(
        context: Context,
        views: RemoteViews,
        data: SharedPreferences
    ) {
        views.setViewVisibility(R.id.widget_active, View.GONE)
        views.setViewVisibility(R.id.widget_idle, View.VISIBLE)
        views.setImageViewBitmap(R.id.idle_icon, idleBitmap(context))
        // Sade "Alarm kur" düğmesi UYGULAMAYI açar (durak seçilecek).
        val open = launchIntent(context, "/alarm/new")
        views.setOnClickPendingIntent(R.id.widget_root, open)
        views.setOnClickPendingIntent(R.id.idle_button, open)

        val rows = listOf(
            Shortcut(R.id.shortcut_0, R.id.shortcut_0_code, R.id.shortcut_0_title,
                R.id.shortcut_0_sub, R.id.shortcut_0_go),
            Shortcut(R.id.shortcut_1, R.id.shortcut_1_code, R.id.shortcut_1_title,
                R.id.shortcut_1_sub, R.id.shortcut_1_go)
        )
        var shown = 0
        rows.forEachIndexed { i, row ->
            val title = data.getString("sc${i}_title", null)
            if (title.isNullOrEmpty()) {
                views.setViewVisibility(row.container, View.GONE)
                return@forEachIndexed
            }
            shown++
            views.setViewVisibility(row.container, View.VISIBLE)
            views.setTextViewText(row.code, data.getString("sc${i}_code", ""))
            views.setTextViewText(row.title, title)
            views.setTextViewText(row.sub, data.getString("sc${i}_sub", ""))
            views.setImageViewBitmap(row.go, playBitmap(context))
            tintChip(views, row.code, colorOf(data.getString("sc${i}_color", null)))
            // Kısayol UYGULAMAYI AÇMAZ: arka planda doğrudan alarmı başlatır.
            views.setOnClickPendingIntent(
                row.container,
                HomeWidgetBackgroundIntent.getBroadcast(
                    context, Uri.parse("stopalert://alarm/start?i=$i")
                )
            )
        }
        views.setTextViewText(
            R.id.idle_subtitle,
            if (shown > 0) context.getString(R.string.widget_shortcut_hint)
            else context.getString(R.string.widget_idle_subtitle)
        )
    }

    private data class Shortcut(
        val container: Int,
        val code: Int,
        val title: Int,
        val sub: Int,
        val go: Int
    )

    /** Kısayoldaki "başlat" üçgeni. */
    private fun playBitmap(context: Context): Bitmap {
        val density = context.resources.displayMetrics.density
        val size = (22 * density).toInt().coerceAtLeast(36)
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawCircle(
            size / 2f, size / 2f, size / 2f - 1f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = BRAND }
        )
        val path = android.graphics.Path().apply {
            val cx = size / 2f
            val r = size / 4.6f
            moveTo(cx - r * 0.55f, cx - r)
            lineTo(cx + r * 0.85f, cx)
            lineTo(cx - r * 0.55f, cx + r)
            close()
        }
        canvas.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
        })
        return bmp
    }

    /** Boş durum simgesi: marka renginde içi boş halka + çan. */
    private fun idleBitmap(context: Context): Bitmap {
        val density = context.resources.displayMetrics.density
        val size = (34 * density).toInt().coerceAtLeast(48)
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val stroke = 3f * density
        val inset = stroke / 2f + 1f
        canvas.drawArc(
            RectF(inset, inset, size - inset, size - inset), 0f, 360f, false,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = stroke
                color = Color.argb(70, 255, 69, 58)
            }
        )
        val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = BRAND }
        canvas.drawCircle(size / 2f, size / 2f, size / 7f, dot)
        return bmp
    }

    private fun bindActive(
        context: Context,
        views: RemoteViews,
        data: SharedPreferences
    ) {
        views.setViewVisibility(R.id.widget_idle, View.GONE)
        views.setViewVisibility(R.id.widget_active, View.VISIBLE)

        val remaining = data.getInt("stops_remaining", 0)
        val total = data.getInt("stops_total", 0).coerceAtLeast(1)
        val state = data.getString("state", "active") ?: "active"
        val accent = parseColor(data.getString("color", null), state)

        views.setImageViewBitmap(
            R.id.ring,
            ringBitmap(context, remaining, total, accent)
        )

        val line = data.getString("line", "") ?: ""
        val target = data.getString("target", "") ?: ""
        views.setTextViewText(R.id.line_code, line)
        // Rozet hat rengini alır. setBackgroundColor kullanılmaz — yuvarlak
        // köşeleri olan drawable'ı düz renkle ezerdi; tint şekli korur.
        // (API 31 öncesinde rozet marka kırmızısı kalır, kabul edilebilir.)
        tintChip(views, R.id.line_code, accent)
        views.setTextViewText(R.id.target_stop, target)

        // Dar widget: iki ayrı satır yerine "şimdiki → sonraki".
        val current = data.getString("current", "") ?: ""
        val next = data.getString("next", "") ?: ""
        views.setTextViewText(
            R.id.stops_line,
            when {
                current.isNotEmpty() && next.isNotEmpty() -> "$current  →  $next"
                next.isNotEmpty() -> "Sonraki: $next"
                else -> current
            }
        )

        val distance = data.getString("distance", "—") ?: "—"
        val eta = data.getInt("eta", 0)
        views.setTextViewText(
            R.id.distance,
            if (eta > 0) "$distance · ~$eta dk" else distance
        )

        views.setTextViewText(R.id.state_label, stateLabel(state, remaining))
        views.setTextColor(R.id.state_label, accent)

        views.setOnClickPendingIntent(R.id.widget_root, launchIntent(context, "/tracking"))
    }

    private fun launchIntent(context: Context, path: String) =
        HomeWidgetLaunchIntent.getActivity(
            context,
            MainActivity::class.java,
            Uri.parse("stopalert://$path")
        )

    private fun stateLabel(state: String, remaining: Int) = when (state) {
        "approaching" -> "İNİYORSUN"
        "signalLost" -> "SİNYAL YOK"
        "arrived" -> "VARDIN"
        "waiting" -> "BİNİŞE GİDİLİYOR"
        else -> if (remaining <= 1) "SON DURAK" else "YOLDA"
    }

    /** Rozeti hat rengine boya (yuvarlak köşeler korunur; API 31+). */
    private fun tintChip(views: RemoteViews, viewId: Int, color: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            views.setColorStateList(
                viewId, "setBackgroundTintList", ColorStateList.valueOf(color)
            )
        }
    }

    /** "#RRGGBB" → renk; çözülemezse marka kırmızısı. */
    private fun colorOf(hex: String?): Int = try {
        Color.parseColor(hex ?: "")
    } catch (_: IllegalArgumentException) {
        BRAND
    }

    /** Hat rengi; yaklaşma/sinyal yok durumlarında uyarı rengine döner. */
    private fun parseColor(hex: String?, state: String): Int {
        if (state == "approaching" || state == "arrived") return BRAND
        if (state == "signalLost") return Color.parseColor("#FFB020")
        return try {
            Color.parseColor(hex ?: "")
        } catch (_: IllegalArgumentException) {
            BRAND
        }
    }

    /**
     * Kalan durak halkası: dış halka ilerleme, ortada kalan durak sayısı.
     *
     * [remaining] hedefe kalan durak, [total] yolculuğun toplam durak sayısı.
     * Dolum "gidilen yol" oranıdır — yolculuk ilerledikçe halka dolar.
     */
    private fun ringBitmap(
        context: Context,
        remaining: Int,
        total: Int,
        accent: Int
    ): Bitmap {
        val density = context.resources.displayMetrics.density
        // Düzendeki ImageView 86dp; bitmap birebir o ölçüde üretilir.
        val size = (86 * density).toInt().coerceAtLeast(120)
        val stroke = 8f * density
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)

        val inset = stroke / 2f + 1f
        val rect = RectF(inset, inset, size - inset, size - inset)

        val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = stroke
            color = Color.argb(46, Color.red(accent), Color.green(accent), Color.blue(accent))
        }
        canvas.drawArc(rect, 0f, 360f, false, track)

        val done = ((total - remaining).toFloat() / total).coerceIn(0f, 1f)
        if (done > 0f) {
            val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = stroke
                strokeCap = Paint.Cap.ROUND
                color = accent
            }
            // -90°: saat 12 yönünden başla.
            canvas.drawArc(rect, -90f, 360f * done, false, arc)
        }

        val number = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textAlign = Paint.Align.CENTER
            textSize = 28f * density
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val caption = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(150, 255, 255, 255)
            textAlign = Paint.Align.CENTER
            textSize = 9.5f * density
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        }
        val cx = size / 2f
        canvas.drawText("$remaining", cx, cx + 4f * density, number)
        canvas.drawText("DURAK", cx, cx + 18f * density, caption)
        return bmp
    }

    private companion object {
        val BRAND: Int = Color.parseColor("#FF453A")
    }
}
