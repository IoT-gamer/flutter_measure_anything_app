/*
 * Copyright 2017 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.google.ar.core.examples.java.common.rendering;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.opengl.GLES20;
import android.opengl.GLUtils;
import java.io.IOException;
import java.io.InputStream;

/**
 * A texture, used for rendering 2D images onto 3D objects.
 */
public class Texture {
  private final int[] textureId = {0};
  private final int[] target = {0};

  /**
   * Creates and initializes the texture. This method needs to be called on a thread with a EGL
   * context attached.
   *
   * @param context Context for loading the texture.
   * @param assetFileName The asset file name of the texture.
   */
  public void createOnGlThread(Context context, String assetFileName) throws IOException {
    final Bitmap bitmap =
        BitmapFactory.decodeStream(context.getAssets().open(assetFileName));

    target[0] = GLES20.GL_TEXTURE_2D;
    GLES20.glGenTextures(1, textureId, 0);
    GLES20.glBindTexture(target[0], textureId[0]);
    GLES20.glTexParameteri(target[0], GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR_MIPMAP_LINEAR);
    GLES20.glTexParameteri(target[0], GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
    GLUtils.texImage2D(target[0], 0, bitmap, 0);
    GLES20.glGenerateMipmap(target[0]);
    GLES20.glBindTexture(target[0], 0);

    bitmap.recycle();
  }

  /**
   * Returns the texture ID.
   */
  public int getTextureId() {
    return textureId[0];
  }
}
