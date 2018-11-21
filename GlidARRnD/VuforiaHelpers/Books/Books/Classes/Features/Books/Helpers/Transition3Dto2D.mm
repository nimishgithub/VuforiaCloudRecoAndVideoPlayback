/*===============================================================================
Copyright (c) 2016-2017 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#include "Transition3Dto2D.h"
#include "SampleApplicationUtils.h"
#include "Quad.h"
#include <sys/time.h>
#include <Vuforia/Tool.h>
#include "VuforiaHelper.h"

// Data for drawing the 3D plane as overlay
static const float planeVertices[] =
{
    -0.5, -0.5, 0.0, 0.5, -0.5, 0.0, 0.5, 0.5, 0.0, -0.5, 0.5, 0.0,
};

static const float planeTexcoords[] =
{
    0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0
};

static const float planeNormals[] =
{
    0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0
};

static const unsigned short planeIndices[] =
{
    0, 1, 2, 0, 2, 3
};

void Transition3Dto2D::updateScreenProperties(int screenWidth, int screenHeight, bool isPortraitMode)
{
    this->isActivityPortraitMode = isPortraitMode;
    this->screenWidth = screenWidth;
    this->screenHeight = screenHeight;
    
    screenRect = Vuforia::Vec4F(0, 0, screenWidth, screenHeight);
    
    for (int i = 0; i < 16; i++)
        orthoMatrix.data[i] = 0.0f;
    float nLeft = -screenWidth / 2.0f;
    float nRight = screenWidth / 2.0f;
    float nBottom = -screenHeight / 2.0f;
    float nTop = screenHeight / 2.0f;
    float nNear = -1.0;
    float nFar = 1.0;
    
    orthoMatrix.data[0] = 2.0f / (nRight - nLeft);
    orthoMatrix.data[5] = 2.0f / (nTop - nBottom);
    orthoMatrix.data[10] = 2.0f / (nNear - nFar);
    orthoMatrix.data[12] = -(nRight + nLeft) / (nRight - nLeft);
    orthoMatrix.data[13] = -(nTop + nBottom) / (nTop - nBottom);
    orthoMatrix.data[14] = (nFar + nNear) / (nFar - nNear);
    orthoMatrix.data[15] = 1.0f;
    
}

Transition3Dto2D::Transition3Dto2D(int screenWidth, int screenHeight, bool isPortraitMode)
{
	this->isActivityPortraitMode = isPortraitMode;
    this->screenWidth = screenWidth;
    this->screenHeight = screenHeight;
    
    screenRect = Vuforia::Vec4F(0, 0, screenWidth, screenHeight);
    
    identityMatrix.data[0] = 1.0f; identityMatrix.data[1] = 0.0f; identityMatrix.data[2] = 0.0f; identityMatrix.data[3] = 0.0f;
    identityMatrix.data[4] = 0.0f; identityMatrix.data[5] = 1.0f; identityMatrix.data[6] = 0.0f; identityMatrix.data[7] = 0.0f;
    identityMatrix.data[8] = 0.0f; identityMatrix.data[9] = 0.0f; identityMatrix.data[10]= 1.0f; identityMatrix.data[11]= 0.0f;
    identityMatrix.data[12]= 0.0f; identityMatrix.data[13]= 0.0f; identityMatrix.data[14]= 0.0f; identityMatrix.data[15]= 1.0f;
    
    for (int i = 0; i < 16; i++) orthoMatrix.data[i] = 0.0f;
    float nLeft   = -screenWidth / 2.0f;
    float nRight  =  screenWidth / 2.0f;
    float nBottom = -screenHeight / 2.0f;
    float nTop    =  screenHeight / 2.0f;
    float nNear   = -1.0;
    float nFar    =  1.0;

    orthoMatrix.data[0]  =  2.0f / (nRight - nLeft);
    orthoMatrix.data[5]  =  2.0f / (nTop - nBottom);
    orthoMatrix.data[10] =  2.0f / (nNear - nFar);
    orthoMatrix.data[12] = -(nRight + nLeft) / (nRight - nLeft);
    orthoMatrix.data[13] = -(nTop + nBottom) / (nTop - nBottom);
    orthoMatrix.data[14] =  (nFar + nNear) / (nFar - nNear);
    orthoMatrix.data[15] =  1.0f;
    
    animationFinished = true;
}


void Transition3Dto2D::initializeGL(unsigned int sProgramID)
{
	shaderProgramID = sProgramID;
    vertexHandle = glGetAttribLocation(shaderProgramID, "vertexPosition");
    normalHandle        = glGetAttribLocation(shaderProgramID,"vertexNormal");
    textureCoordHandle = glGetAttribLocation(shaderProgramID, "vertexTexCoord");
    mvpMatrixHandle = glGetUniformLocation(shaderProgramID, "modelViewProjectionMatrix");
    
    SampleApplicationUtils::checkGlError("Transition3Dto2D::initializeGL");
}


void Transition3Dto2D::setScreenRect(int centerX, int centerY, int width, int height)
{
    screenRect = Vuforia::Vec4F(centerX, centerY, width, height);
}


void Transition3Dto2D::startTransition(float duration, bool inReverse, bool keepRendering)
{
    animationLength = duration;
    animationDirection = inReverse ? -1 : 1;
    renderAfterCompletion = keepRendering;

    animationStartTime = getCurrentTimeMS();
    animationFinished = false;
}


float Transition3Dto2D::stepTransition()
{
    float timeElapsed = (getCurrentTimeMS() - animationStartTime) / 1000.0f;
    
    float t = timeElapsed / animationLength;
    if (t >= 1.0f)
    {
        t = 1.0f;
        animationFinished = true;
    }
    
    if (animationDirection == -1)
    {
        t = 1.0f - t;
    }
    
    return t;
}


void Transition3Dto2D::render(Vuforia::Matrix44F projectionMatrix, Vuforia::Matrix34F targetPose, Vuforia::Vec2F trackableSize, GLuint texture1)
{
    float t = stepTransition();
    
    Vuforia::Matrix44F modelViewProjectionTracked;
    Vuforia::Matrix44F modelViewProjectionCurrent;
    Vuforia::Matrix44F modelViewMatrix = Vuforia::Tool::convertPose2GLMatrix(targetPose);
    Vuforia::Matrix44F finalPositionMatrix = getFinalPositionMatrix();

    SampleApplicationUtils::scalePoseMatrix(trackableSize.data[0]*1.2f,
                                 trackableSize.data[0]*0.58f,
                                 1.0f,
                                 &modelViewMatrix.data[0]);

    SampleApplicationUtils::multiplyMatrix(&projectionMatrix.data[0],
                                &modelViewMatrix.data[0] ,
                                &modelViewProjectionTracked.data[0]);
    
    float elapsedTransformationCurrent = t;
    elapsedTransformationCurrent = deccelerate(elapsedTransformationCurrent);
    linearInterpolate(&modelViewProjectionTracked, &finalPositionMatrix, &modelViewProjectionCurrent, elapsedTransformationCurrent);

    glUseProgram(shaderProgramID);

    glVertexAttribPointer(vertexHandle, 3, GL_FLOAT, GL_FALSE, 0,
    		(const GLvoid*) &planeVertices[0]);
    glVertexAttribPointer(normalHandle, 3, GL_FLOAT, GL_FALSE, 0,
    		(const GLvoid*) &planeNormals[0]);
    glVertexAttribPointer(textureCoordHandle, 2, GL_FLOAT, GL_FALSE, 0,
    		(const GLvoid*) &planeTexcoords[0]);

    glEnableVertexAttribArray(vertexHandle);
    glEnableVertexAttribArray(normalHandle);
    glEnableVertexAttribArray(textureCoordHandle);
    glEnable(GL_BLEND);

    //Drawing Textured Plane
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture1);
    glUniformMatrix4fv(mvpMatrixHandle, 1, GL_FALSE,
    		(GLfloat*)&modelViewProjectionCurrent.data[0] );
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT,
    		(const GLvoid*) &planeIndices[0]);

    glDisableVertexAttribArray(vertexHandle);
    glDisableVertexAttribArray(normalHandle);
    glDisableVertexAttribArray(textureCoordHandle);
    glDisable(GL_BLEND);

    SampleApplicationUtils::checkGlError("Transition3Dto2D::render");

}

bool Transition3Dto2D::transitionFinished()
{
    return animationFinished;
}


Vuforia::Matrix44F Transition3Dto2D::getFinalPositionMatrix()
{
    float tempValue;
    float viewport[4];
    glGetFloatv(GL_VIEWPORT, &viewport[0]);
    
    // Sometimes the screenWidth and screenHeight values
    // are not properly updated, so this workaround
    // ensures that it will work fine every time
    if (this->isActivityPortraitMode)
    {
        if (screenWidth > screenHeight)
        {
            tempValue = screenWidth;
            screenWidth = screenHeight;
            screenHeight = tempValue;
        }
    }
    else
    {
        if (screenWidth < screenHeight)
        {
            tempValue = screenWidth;
            screenWidth = screenHeight;
            screenHeight = tempValue;
        }
    }
    
    float scaleFactorX = screenWidth / viewport[2];
    float scaleFactorY = screenHeight / viewport[3];
    
    float translateX = screenRect.data[0] * scaleFactorX;
    float translateY = screenRect.data[1] * scaleFactorY;
    
    Vuforia::Matrix44F result = orthoMatrix;
    SampleApplicationUtils::translatePoseMatrix(translateX, translateY, 0.0f, &result.data[0]);

    float x = 0;
    float y = 0;
    
    if([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad)
    {
        //  iPad
        x = 1024;
        y = 512;
    }
    else
    {
        //  iPhone
        x = 512;
        y = 256;
    }
    
    if ([VuforiaHelper isRetinaDevice])
    {
        x *= [UIScreen mainScreen].nativeScale;
        y *= [UIScreen mainScreen].nativeScale;
    }
    
    SampleApplicationUtils::scalePoseMatrix(x * scaleFactorX,
                                 y * scaleFactorY,
                                 1.0f,
                                 &result.data[0]);
    
    return result;
}



float Transition3Dto2D::deccelerate(float val)
{
    return (1-((1-val)*(1-val)));
}

float Transition3Dto2D::accelerate(float val)
{
    return val*val;
}

void Transition3Dto2D::linearInterpolate(Vuforia::Matrix44F* start, Vuforia::Matrix44F* end, Vuforia::Matrix44F* current, float elapsed)
{
    // Note, this is a plain matrix linear interpolation.  A better approach
    // would be to interpolate the modelview and projection matrices separately
    // and to use some sort of curve, such as bezier
    for (int i = 0; i < 16; i++) current->data[i] = ((end->data[i] - start->data[i]) * elapsed) + start->data[i];
}


unsigned long Transition3Dto2D::getCurrentTimeMS()
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    unsigned long s = tv.tv_sec * 1000;
    unsigned long us = tv.tv_usec / 1000;
    return s + us;
}

