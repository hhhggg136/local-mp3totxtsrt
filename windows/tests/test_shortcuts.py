"""Playback shortcuts must preserve editing and avoid key-repeat toggles."""
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from tingting.gui import Workspace


class ShortcutTests(unittest.TestCase):
    def setUp(self):
        self.workspace=Workspace.__new__(Workspace)
        self.workspace.space_down=False
        self.workspace.project=object()
        self.workspace.play=Mock()
        self.workspace.guard=lambda fn:fn()

    def event(self,kind='Treeview'):
        return SimpleNamespace(widget=SimpleNamespace(winfo_class=lambda:kind))

    def test_space_toggles_once_until_release(self):
        w=self.workspace
        self.assertEqual(w.space_press(self.event()),'break')
        w.space_press(self.event())
        w.play.assert_called_once()
        w.space_release(self.event())
        w.space_press(self.event('Canvas'))
        self.assertEqual(w.play.call_count,2)

    def test_editing_and_native_controls_keep_space(self):
        for kind in ('Entry','TEntry','Text','TCombobox','Button','TButton','Spinbox','TSpinbox'):
            self.assertIsNone(self.workspace.space_press(self.event(kind)))
        self.workspace.play.assert_not_called()

    def test_empty_workspace_does_not_start_playback(self):
        self.workspace.project=None
        self.workspace.space_press(self.event())
        self.workspace.play.assert_not_called()
