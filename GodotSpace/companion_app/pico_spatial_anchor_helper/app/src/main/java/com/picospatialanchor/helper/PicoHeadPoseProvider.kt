package com.picospatialanchor.helper

import android.content.Context
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject
import java.lang.reflect.Field

class PicoHeadPoseProvider(context: Context) {

    private val appContext = context.applicationContext

    private var utilsInstance: Any? = null
    private var bindState: String = STATE_NOT_INITIALIZED
    private var lastErrorMessage: String = ""
    private var lastBindAttemptElapsedMs: Long = 0L

    fun start() {
        synchronized(this) {
            val helper = ensureHelperInstanceLocked() ?: return
            requestBindLocked(helper, force = true)
        }
    }

    fun stop() {
        synchronized(this) {
            val helper = utilsInstance ?: return
            runCatching {
                invokeNoArgMethod(helper, METHOD_UNBIND_SERVICE)
            }.onFailure { throwable ->
                Log.w(TAG, "unBindTobService failed", throwable)
            }
            bindState = STATE_UNBOUND
        }
    }

    fun snapshot(): HeadPoseSnapshot {
        synchronized(this) {
            val helper = ensureHelperInstanceLocked()
                ?: return HeadPoseSnapshot(
                    available = false,
                    bindState = bindState,
                    error = lastErrorMessage,
                )

            requestBindLocked(helper, force = false)

            val binder = runCatching {
                invokeNoArgMethod(helper, METHOD_GET_SERVICE_BINDER)
            }.getOrElse { throwable ->
                lastErrorMessage = describeError("getServiceBinder", throwable)
                bindState = STATE_BINDING
                return HeadPoseSnapshot(
                    available = false,
                    bindState = bindState,
                    error = lastErrorMessage,
                )
            }

            if (binder == null) {
                bindState = STATE_BINDING
                return HeadPoseSnapshot(
                    available = false,
                    bindState = bindState,
                    error = "binder_null",
                )
            }

            bindState = STATE_BOUND
            val trackingStatusRaw = runCatching {
                invokeNoArgMethod(binder, METHOD_GET_HEAD_TRACKING_STATUS)?.toString()
            }.getOrElse { throwable ->
                lastErrorMessage = describeError("getHeadTrackingStatus", throwable)
                null
            }

            val pose = runCatching {
                invokeLongMethod(
                    target = binder,
                    methodName = METHOD_GET_HEAD_POSE,
                    argument = DEFAULT_PREDICT_TIME_MS,
                )
            }.getOrElse { throwable ->
                lastErrorMessage = describeError("getHeadPose", throwable)
                return HeadPoseSnapshot(
                    available = false,
                    bindState = bindState,
                    trackingStatusRaw = trackingStatusRaw,
                    error = lastErrorMessage,
                )
            }

            if (pose == null) {
                return HeadPoseSnapshot(
                    available = false,
                    bindState = bindState,
                    trackingStatusRaw = trackingStatusRaw,
                    error = "pose_null",
                )
            }

            return HeadPoseSnapshot(
                available = true,
                bindState = bindState,
                trackingStatusRaw = trackingStatusRaw,
                predictTimeMs = DEFAULT_PREDICT_TIME_MS,
                timestamp = readLongField(pose, "timestamp"),
                x = readDoubleField(pose, "x"),
                y = readDoubleField(pose, "y"),
                z = readDoubleField(pose, "z"),
                rw = readDoubleField(pose, "rw"),
                rx = readDoubleField(pose, "rx"),
                ry = readDoubleField(pose, "ry"),
                rz = readDoubleField(pose, "rz"),
                type = readFieldValue(pose, "type")?.toString(),
                confidence = readFieldValue(pose, "confidence")?.toString(),
                poseError = readFieldValue(pose, "poseError")?.toString(),
                rawPoseString = pose.toString(),
            )
        }
    }

    private fun ensureHelperInstanceLocked(): Any? {
        if (utilsInstance != null) {
            return utilsInstance
        }
        if (bindState == STATE_UNAVAILABLE && lastErrorMessage.isNotEmpty()) {
            return null
        }

        return runCatching {
            val helperClass = Class.forName(CLASS_TOB_SERVICE_HELPER)
            val instance = helperClass.getMethod(METHOD_GET_INSTANCE).invoke(null)
            instance.also {
                utilsInstance = it
                bindState = STATE_READY
                lastErrorMessage = ""
            }
        }.getOrElse { throwable ->
            bindState = STATE_UNAVAILABLE
            lastErrorMessage = describeError("load_helper", throwable)
            Log.w(TAG, "ToB helper unavailable", throwable)
            null
        }
    }

    private fun requestBindLocked(helper: Any, force: Boolean) {
        val nowMs = SystemClock.elapsedRealtime()
        if (!force && nowMs - lastBindAttemptElapsedMs < REBIND_INTERVAL_MS) {
            return
        }
        lastBindAttemptElapsedMs = nowMs

        runCatching {
            helper.javaClass
                .getMethod(METHOD_BIND_SERVICE, Context::class.java)
                .invoke(helper, appContext)
            if (bindState != STATE_BOUND) {
                bindState = STATE_BINDING
            }
        }.onFailure { throwable ->
            bindState = STATE_BIND_FAILED
            lastErrorMessage = describeError("bindTobService", throwable)
            Log.w(TAG, "bindTobService failed", throwable)
        }
    }

    private fun invokeNoArgMethod(target: Any, methodName: String): Any? {
        return target.javaClass.getMethod(methodName).invoke(target)
    }

    private fun invokeLongMethod(target: Any, methodName: String, argument: Long): Any? {
        return target.javaClass
            .getMethod(methodName, java.lang.Long.TYPE)
            .invoke(target, argument)
    }

    private fun readFieldValue(target: Any, fieldName: String): Any? {
        return findField(target.javaClass, fieldName)?.get(target)
    }

    private fun readDoubleField(target: Any, fieldName: String): Double? {
        return (readFieldValue(target, fieldName) as? Number)?.toDouble()
    }

    private fun readLongField(target: Any, fieldName: String): Long? {
        return (readFieldValue(target, fieldName) as? Number)?.toLong()
    }

    private fun findField(type: Class<*>, fieldName: String): Field? {
        var current: Class<*>? = type
        while (current != null) {
            val field = runCatching { current.getDeclaredField(fieldName) }.getOrNull()
            if (field != null) {
                field.isAccessible = true
                return field
            }
            current = current.superclass
        }
        return null
    }

    private fun describeError(stage: String, throwable: Throwable): String {
        val rootCause = generateSequence(throwable) { it.cause }.last()
        val parts = mutableListOf(stage, throwable.javaClass.simpleName)
        val rootName = rootCause.javaClass.simpleName
        if (rootName != throwable.javaClass.simpleName) {
            parts += rootName
        }
        val message = rootCause.message?.takeIf { it.isNotBlank() }
        if (message != null) {
            parts += message
        }
        return parts.joinToString(":")
    }

    data class HeadPoseSnapshot(
        val available: Boolean,
        val bindState: String,
        val trackingStatusRaw: String? = null,
        val predictTimeMs: Long = 0L,
        val timestamp: Long? = null,
        val x: Double? = null,
        val y: Double? = null,
        val z: Double? = null,
        val rw: Double? = null,
        val rx: Double? = null,
        val ry: Double? = null,
        val rz: Double? = null,
        val type: String? = null,
        val confidence: String? = null,
        val poseError: String? = null,
        val rawPoseString: String? = null,
        val error: String? = null,
    ) {
        fun appendTo(metadata: JSONObject) {
            metadata
                .put("head_pose_provider", "pico_tobservice_getHeadPose")
                .put("head_pose_bind_state", bindState)
                .put("head_pose_available", available)
                .put("head_pose_predict_time_ms", predictTimeMs)

            trackingStatusRaw?.let { metadata.put("head_tracking_status_raw", it) }
            timestamp?.let { metadata.put("head_pose_timestamp", it) }
            x?.let { metadata.put("head_pose_x", it) }
            y?.let { metadata.put("head_pose_y", it) }
            z?.let { metadata.put("head_pose_z", it) }
            rw?.let { metadata.put("head_pose_rw", it) }
            rx?.let { metadata.put("head_pose_rx", it) }
            ry?.let { metadata.put("head_pose_ry", it) }
            rz?.let { metadata.put("head_pose_rz", it) }
            type?.let { metadata.put("head_pose_type", it) }
            confidence?.let { metadata.put("head_pose_confidence", it) }
            poseError?.let { metadata.put("head_pose_error_type", it) }
            rawPoseString?.let { metadata.put("head_pose_raw", it) }
            error?.let { metadata.put("head_pose_error", it) }
        }
    }

    companion object {
        private const val TAG = "PicoHeadPoseProvider"
        private const val CLASS_TOB_SERVICE_HELPER = "com.pvr.tobservice.ToBServiceHelper"
        private const val METHOD_GET_INSTANCE = "getInstance"
        private const val METHOD_BIND_SERVICE = "bindTobService"
        private const val METHOD_UNBIND_SERVICE = "unBindTobService"
        private const val METHOD_GET_SERVICE_BINDER = "getServiceBinder"
        private const val METHOD_GET_HEAD_TRACKING_STATUS = "getHeadTrackingStatus"
        private const val METHOD_GET_HEAD_POSE = "getHeadPose"
        private const val REBIND_INTERVAL_MS = 3_000L
        private const val DEFAULT_PREDICT_TIME_MS = 0L

        private const val STATE_NOT_INITIALIZED = "not_initialized"
        private const val STATE_READY = "ready"
        private const val STATE_BINDING = "binding"
        private const val STATE_BOUND = "bound"
        private const val STATE_BIND_FAILED = "bind_failed"
        private const val STATE_UNBOUND = "unbound"
        private const val STATE_UNAVAILABLE = "unavailable"
    }
}
