package com.picospatialanchor.helper

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.pvr.tobservice.interfaces.IIntCallback
import java.lang.reflect.Method

/**
 * Thin, version-tolerant wrapper around PICO ToB's screencast APIs.
 *
 * The helper already obtains ToB head poses through reflection because PICO
 * service interfaces differ between firmware packages. Keeping the same
 * approach here allows the companion to report a useful error on unsupported
 * devices instead of crashing during class loading.
 */
class PicoCastProvider(
    context: Context,
    private val onConnectionStateChanged: (Int) -> Unit = {},
) {

    private val appContext = context.applicationContext
    private var helperInstance: Any? = null
    private val castConnectionCallback = object : IIntCallback.Stub() {
        override fun callback(value: Int) {
            Log.i(TAG, "PICO Cast connection state changed: $value")
            onConnectionStateChanged(value)
        }
    }

    fun start(): Result {
        val helper = ensureHelper() ?: return Result.failure("PICO ToB service unavailable")
        return runCatching {
            requestBind(helper)

            var binder: Any? = null
            for (attempt in 0 until BIND_ATTEMPTS) {
                binder = runCatching { invokeNoArg(helper, METHOD_GET_SERVICE_BINDER) }.getOrNull()
                if (binder != null) {
                    break
                }
                if (attempt + 1 < BIND_ATTEMPTS) {
                    SystemClock.sleep(BIND_RETRY_DELAY_MS)
                }
            }
            val service = binder
                ?: return@runCatching Result.failure("PICO ToB service is still binding")

            val initResult = invokeByName(
                service,
                METHOD_CAST_INIT,
                arrayOf(castConnectionCallback, 0),
            ) as? Number
            if (initResult?.toInt() != SUCCESS) {
                return@runCatching Result.failure(
                    "PICO Cast initialization failed: ${initResult?.toInt() ?: "no result"}",
                )
            }

            setOption(
                service,
                "OPTION_AUDIO_ENABLE",
                "OPTION_VALUE_AUDIO_OFF",
            )
            setOption(
                service,
                "OPTION_RESOLUTION_LEVEL",
                "OPTION_VALUE_RESOLUTION_MIDDLE",
            )
            setOption(
                service,
                "OPTION_BITRATE_LEVEL",
                "OPTION_VALUE_BITRATE_MIDDLE",
            )
            setKeepRecordingWhenScreenOff(service, enabled = true)
            setCastWakeLock(service, acquired = true)

            val urlType = enumValue(CLASS_CAST_URL_TYPE, "RTMP_URL")
            var url = ""
            for (attempt in 0 until URL_ATTEMPTS) {
                url = invokeByName(
                    service,
                    METHOD_CAST_GET_URL,
                    arrayOf(urlType, 0),
                )?.toString()?.trim().orEmpty()
                if (url.startsWith("rtmp://") || url.startsWith("rtmps://")) {
                    break
                }
                if (attempt + 1 < URL_ATTEMPTS) {
                    SystemClock.sleep(URL_RETRY_DELAY_MS)
                }
            }
            if (!url.startsWith("rtmp://") && !url.startsWith("rtmps://")) {
                return@runCatching Result.failure(
                    "PICO Cast did not return an RTMP URL after $URL_ATTEMPTS attempts",
                )
            }
            Result.success(url)
        }.getOrElse { throwable ->
            Log.w(TAG, "PICO Cast start failed", throwable)
            Result.failure(describeError("start", throwable))
        }
    }

    fun stop(): String? {
        val helper = helperInstance ?: return null
        val service = runCatching { invokeNoArg(helper, METHOD_GET_SERVICE_BINDER) }.getOrNull()
            ?: return "PICO ToB service is unavailable"
        val stopError = runCatching {
            val result = invokeByName(service, METHOD_CAST_STOP, arrayOf(0)) as? Number
            if (result?.toInt() == SUCCESS) {
                null
            } else {
                "PICO Cast stop failed: ${result?.toInt() ?: "no result"}"
            }
        }.getOrElse { throwable ->
            Log.w(TAG, "PICO Cast stop failed", throwable)
            describeError("stop", throwable)
        }
        setCastWakeLock(service, acquired = false)
        setKeepRecordingWhenScreenOff(service, enabled = false)
        return stopError
    }

    fun unbind() {
        val helper = helperInstance ?: return
        runCatching {
            helper.javaClass
                .getMethod(METHOD_UNBIND_SERVICE, Context::class.java)
                .invoke(helper, appContext)
        }.onFailure { throwable ->
            Log.w(TAG, "unBindTobService failed", throwable)
        }
    }

    private fun ensureHelper(): Any? {
        if (helperInstance != null) {
            return helperInstance
        }
        return runCatching {
            Class.forName(CLASS_TOB_SERVICE_HELPER)
                .getMethod(METHOD_GET_INSTANCE)
                .invoke(null)
                .also { helperInstance = it }
        }.getOrElse { throwable ->
            Log.w(TAG, "PICO ToB helper unavailable", throwable)
            null
        }
    }

    private fun requestBind(helper: Any) {
        helper.javaClass
            .getMethod(METHOD_BIND_SERVICE, Context::class.java)
            .invoke(helper, appContext)
    }

    private fun setOption(service: Any, optionName: String, valueName: String) {
        val result = invokeByName(
            service,
            METHOD_CAST_SET_OPTION,
            arrayOf(
                enumValue(CLASS_CAST_OPTION, optionName),
                enumValue(CLASS_CAST_OPTION_VALUE, valueName),
                0,
            ),
        ) as? Number
        if (result?.toInt() != SUCCESS) {
            throw IllegalStateException(
                "PICO Cast option $optionName failed: ${result?.toInt() ?: "no result"}",
            )
        }
    }

    private fun setKeepRecordingWhenScreenOff(service: Any, enabled: Boolean) {
        runCatching {
            invokeByName(
                service,
                METHOD_SWITCH_SYSTEM_FUNCTION,
                arrayOf(
                    enumValue(
                        CLASS_SYSTEM_FUNCTION_SWITCH,
                        "SFS_KEEP_RECORD_WHEN_SCREEN_OFF",
                    ),
                    enumValue(
                        CLASS_SWITCH,
                        if (enabled) "S_ON" else "S_OFF",
                    ),
                    0,
                ),
            )
        }.onSuccess {
            Log.i(TAG, "Keep recording when screen off: $enabled")
        }.onFailure { throwable ->
            // Older firmware may not expose this switch. PICO Cast can still
            // run while the headset is awake, so treat it as a compatibility
            // warning instead of failing the whole session.
            Log.w(TAG, "Unable to change screen-off recording policy", throwable)
        }
    }

    private fun setCastWakeLock(service: Any, acquired: Boolean) {
        runCatching {
            if (acquired) {
                invokeNoArg(service, METHOD_ACQUIRE_WAKE_LOCK)
                invokeNoArg(service, METHOD_SCREEN_ON)
            } else {
                invokeNoArg(service, METHOD_RELEASE_WAKE_LOCK)
            }
        }.onSuccess {
            Log.i(TAG, "PICO Cast wake lock acquired: $acquired")
        }.onFailure { throwable ->
            Log.w(TAG, "Unable to change PICO Cast wake lock", throwable)
        }
    }

    private fun enumValue(className: String, fieldName: String): Any {
        return Class.forName(className).getField(fieldName).get(null)
    }

    private fun invokeNoArg(target: Any, methodName: String): Any? {
        return target.javaClass.getMethod(methodName).invoke(target)
    }

    private fun invokeByName(target: Any, methodName: String, args: Array<Any?>): Any? {
        val method = target.javaClass.methods.firstOrNull {
            it.name == methodName && it.parameterTypes.size == args.size
        } ?: throw NoSuchMethodException("$methodName/${args.size}")
        return method.invoke(target, *args)
    }

    private fun describeError(stage: String, throwable: Throwable): String {
        val root = generateSequence(throwable) { it.cause }.last()
        val detail = root.message?.take(120).orEmpty()
        return if (detail.isEmpty()) {
            "$stage: ${root.javaClass.simpleName}"
        } else {
            "$stage: ${root.javaClass.simpleName} - $detail"
        }
    }

    data class Result(
        val rtmpUrl: String? = null,
        val error: String? = null,
    ) {
        val isSuccess: Boolean get() = !rtmpUrl.isNullOrBlank()

        companion object {
            fun success(rtmpUrl: String): Result = Result(rtmpUrl = rtmpUrl)
            fun failure(error: String): Result = Result(error = error)
        }
    }

    companion object {
        private const val TAG = "PicoCastProvider"
        private const val CLASS_TOB_SERVICE_HELPER = "com.pvr.tobservice.ToBServiceHelper"
        private const val CLASS_CAST_URL_TYPE = "com.pvr.tobservice.enums.PBS_PICOCastUrlTypeEnum"
        private const val CLASS_CAST_OPTION = "com.pvr.tobservice.enums.PBS_PICOCastOptionOrStatusEnum"
        private const val CLASS_CAST_OPTION_VALUE = "com.pvr.tobservice.enums.PBS_PICOCastOptionValueEnum"
        private const val CLASS_SYSTEM_FUNCTION_SWITCH =
            "com.pvr.tobservice.enums.PBS_SystemFunctionSwitchEnum"
        private const val CLASS_SWITCH = "com.pvr.tobservice.enums.PBS_SwitchEnum"
        private const val METHOD_GET_INSTANCE = "getInstance"
        private const val METHOD_BIND_SERVICE = "bindTobService"
        private const val METHOD_UNBIND_SERVICE = "unBindTobService"
        private const val METHOD_GET_SERVICE_BINDER = "getServiceBinder"
        private const val METHOD_CAST_INIT = "pbsPicoCastInit"
        private const val METHOD_CAST_GET_URL = "pbsPicoCastGetUrl"
        private const val METHOD_CAST_STOP = "pbsPicoCastStopCast"
        private const val METHOD_CAST_SET_OPTION = "pbsPicoCastSetOption"
        private const val METHOD_SWITCH_SYSTEM_FUNCTION = "pbsSwitchSystemFunction"
        private const val METHOD_ACQUIRE_WAKE_LOCK = "pbsAcquireWakeLock"
        private const val METHOD_RELEASE_WAKE_LOCK = "pbsReleaseWakeLock"
        private const val METHOD_SCREEN_ON = "pbsScreenOn"
        private const val SUCCESS = 1
        private const val BIND_ATTEMPTS = 10
        private const val BIND_RETRY_DELAY_MS = 300L
        private const val URL_ATTEMPTS = 10
        private const val URL_RETRY_DELAY_MS = 200L
    }
}
