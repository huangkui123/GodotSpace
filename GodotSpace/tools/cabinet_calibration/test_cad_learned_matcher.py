from copy import deepcopy
import json
from unittest import TestCase

import numpy as np

from cad_learned_matcher import choose_candidate, eligible_pose


def candidate():
    return {'camera_from_model': np.eye(4).tolist(), 'score': 20., 'inliers': 40,
            'image_hull_area_px2': 40000., 'inlier_object_span_m': [.2, .4, .3]}


class LearnedCadGuards(TestCase):
    def test_distributed_support_is_eligible(self):
        self.assertTrue(eligible_pose(candidate(), (720, 960, 3), .61))
        self.assertEqual(json.dumps(eligible_pose(candidate(), (720, 960, 3), np.float64(.61))), 'true')

    def test_small_repeated_fittings_cannot_identify_a_cabinet(self):
        p = candidate()
        p['inlier_object_span_m'][1] = .03
        self.assertFalse(eligible_pose(p, (720, 960, 3), .61))
        p = candidate()
        p['image_hull_area_px2'] = 2000
        self.assertFalse(eligible_pose(p, (720, 960, 3), .61))

    def test_too_few_matches_and_failed_pnp_rejected(self):
        p = candidate()
        p['inliers'] = 19
        self.assertFalse(eligible_pose(p, (720, 960, 3), .61))
        self.assertFalse(eligible_pose(None, (720, 960, 3), .61))

    def test_competing_strong_locations_remain_ambiguous(self):
        p, other = candidate(), candidate()
        other['camera_from_model'][0][3] = .2
        self.assertEqual(choose_candidate([p, other])['status'], 'ambiguous')

    def test_competing_strong_rotations_remain_ambiguous(self):
        p, other = candidate(), candidate()
        other['camera_from_model'] = np.diag([-1, 1, -1, 1]).tolist()
        self.assertEqual(choose_candidate([p, other])['status'], 'ambiguous')

    def test_agreeing_views_and_empty_results(self):
        p = candidate()
        other = deepcopy(p)
        other['camera_from_model'][0][3] = .005
        self.assertEqual(choose_candidate([p, other])['status'], 'candidate')
        self.assertEqual(choose_candidate([])['status'], 'not_found')
