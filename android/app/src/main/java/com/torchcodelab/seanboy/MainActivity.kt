package com.torchcodelab.seanboy

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import com.torchcodelab.seanboy.ui.NotesViewModel
import com.torchcodelab.seanboy.ui.SeanboyApp
import com.torchcodelab.seanboy.ui.theme.SeanboyTheme

/**
 * Single-Activity host. Builds the [NotesViewModel] (which owns the local store
 * and sync engine) and renders the app. On-demand sync fires on resume, per the
 * battery-friendly design in docs/PRD-android-v1.md.
 */
class MainActivity : ComponentActivity() {
    private var vm: NotesViewModel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            SeanboyTheme {
                val model: NotesViewModel = viewModel()
                vm = model
                SeanboyApp(model)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // Pick up any external changes, then sync if credentials are set.
        vm?.let { model ->
            model.reloadFromDisk()
            model.syncNow()
        }
    }
}
