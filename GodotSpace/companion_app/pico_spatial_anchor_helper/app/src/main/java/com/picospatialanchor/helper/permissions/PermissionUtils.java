package com.picospatialanchor.helper.permissions;

import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;


public class PermissionUtils {

    public static final int VERSION_CODES_M = 23;

    public static final int CHECK_RESULT_OK = 1;
    public static final int CHECK_RESULT_REFUSE_ONCE = 2;
    public static final int CHECK_RESULT_FAIL = 3;
    public static final int REQUEST_CODE = 5;

    public static int checkPermission(Activity activity, String[] permissions, boolean isFirstRequest) {
        int resultCode;
        if (isPermissionGranted(activity, permissions)) {
            resultCode = CHECK_RESULT_OK;
        } else {

            // if first request permission do requestPermissions
            if (isFirstRequest) {
                ActivityCompat.requestPermissions(activity, permissions, REQUEST_CODE);
                resultCode = CHECK_RESULT_FAIL;
            } else if (isRefuseOncePermission(activity, permissions)) {
                //if permission is refuse once , need request permission
                ActivityCompat.requestPermissions(activity, permissions, REQUEST_CODE);
                resultCode = CHECK_RESULT_REFUSE_ONCE;
            } else {
                resultCode = CHECK_RESULT_FAIL;
            }
        }
        return resultCode;
    }

    /**
     * Determine whether to get permission
     */
    public static boolean isPermissionGranted(Activity activity, String[] permissions) {
        if (Build.VERSION.SDK_INT >= VERSION_CODES_M) {
            for (String permission : permissions) {
                int checkPermission = ContextCompat.checkSelfPermission(activity, permission);
                if (checkPermission != PackageManager.PERMISSION_GRANTED) {
                    return false;
                }
            }
            return true;
        } else {
            return true;
        }
    }

    /**
     * Determine whether to get permission
     */
    public static boolean isPermissionGranted(Context context, String[] permissions) {
        if (Build.VERSION.SDK_INT >= VERSION_CODES_M) {
            for (String permission : permissions) {
                int checkPermission = ContextCompat.checkSelfPermission(context, permission);
                if (checkPermission != PackageManager.PERMISSION_GRANTED) {
                    return false;
                }
            }
            return true;
        } else {
            return true;
        }
    }

    /**
     * If in an permission request, chose refuse once return true, if you choose to reject will return false
     */
    static boolean isRefuseOncePermission(Activity activity, String[] permissions) {
        boolean hasShowRequest = true;
        for (String permission : permissions) {
            //if permission refuse once shouldShowRequestPermissionRationale() method return true
            if (!activity.shouldShowRequestPermissionRationale(permission)) {
                hasShowRequest = false;
                break;
            }
        }
        return hasShowRequest;
    }
}
