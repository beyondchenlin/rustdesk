package com.carriez.flutter_hbb

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import ffi.FFI
import java.util.Locale

/**
 * Private visible activity in a separate process. No background launch, saved projection
 * token or permission claim is used. The original process must be gone before reopening.
 */
class BkProfileRestartActivity : Activity() {
    companion object {
        const val EXTRA_OLD_PID = "bk_profile_old_pid"
    }

    private var scheduled = false
    private val handler = Handler(Looper.getMainLooper())
    private fun translated(value: String): String =
        FFI.translateLocale(Locale.getDefault().toLanguageTag(), value)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply {
            text = translated("Restarting to activate the server profile")
            setPadding(32, 64, 32, 32)
        })
    }

    override fun onResume() {
        super.onResume()
        if (scheduled) return
        scheduled = true
        handler.postDelayed({ restartMainProcess() }, 800)
    }

    private fun restartMainProcess() {
        val oldPid = intent.getIntExtra(EXTRA_OLD_PID, -1)
        if (oldPid <= 0 || oldPid == Process.myPid()) {
            showFailure()
            return
        }
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val old = manager.runningAppProcesses?.firstOrNull { it.pid == oldPid }
        if (old != null) {
            if (old.uid != Process.myUid() || old.processName != packageName) {
                showFailure()
                return
            }
            Process.killProcess(oldPid)
        }
        // Missing process visibility never implies that the old native caches were discarded.
        awaitExit(oldPid, 0)
    }

    private fun awaitExit(pid: Int, attempt: Int) {
        try {
            Os.kill(pid, 0)
            if (attempt >= 50) {
                showFailure()
                return
            }
            handler.postDelayed({ awaitExit(pid, attempt + 1) }, 100)
        } catch (error: ErrnoException) {
            if (error.errno == OsConstants.ESRCH) reopenMain() else showFailure()
        }
    }

    private fun reopenMain() {
        try {
            startActivity(Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            })
            finish()
        } catch (error: Exception) {
            showFailure()
        }
    }

    private fun showFailure() {
        // Keep a visible, user-controlled retry path; never reuse the old native process.
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 64, 32, 32)
            addView(TextView(this@BkProfileRestartActivity).apply {
                text = translated("The application restart was not accepted")
            })
            addView(Button(this@BkProfileRestartActivity).apply {
                text = translated("Retry")
                setOnClickListener { restartMainProcess() }
            })
        })
    }
}
