/*
 * CPU-side matrix generator for the proposed FPGA GPU.
 *
 * This follows the complete transform order pictured on page 3 of docs/gpu.pdf:
 *   model = T(object) * Ry(object yaw) * Rx(object pitch) * Rz(object roll)
 *   view  = Rz(-camera roll) * Rx(-camera pitch) * Ry(-camera yaw) * T(-camera)
 *   final = projection * view * model
 *
 * Matrices use column vectors and are printed in ROW-MAJOR order. The 16
 * printed words are signed 32-bit Q16.16 coefficients, not floating point.
 * The FPGA would calculate h = final * (x,y,z,1), reject h.w < near, then:
 *   screen_x = width/2  + h.x/h.w
 *   screen_y = height/2 - h.y/h.w
 * GPU_Pipeline now loads this matrix and plots the supplied vertices into RAM.
 * Use --scene input.txt output.hex to supply camera/object settings and points,
 * --self-test for checks, or --matrix-test for a multiplication walkthrough.
 */

#ifdef _MSC_VER
#define _CRT_SECURE_NO_WARNINGS
#endif
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define Q16_SCALE 65536.0
#define PI 3.14159265358979323846

typedef struct { double x, y, z; } Vec3;
typedef struct { double yaw, pitch, roll; } Angles;
typedef struct { double a[4][4]; } Mat4;

typedef struct {
    Vec3 object_position;
    Angles object_angle;
    Vec3 camera_position;
    Angles camera_angle;
    int width, height;
    double focal_pixels;
    double near_distance;
} Scene;

typedef struct {
    Mat4 model, view, projection, final;
    int32_t final_q16[16];
    int32_t near_q16;
} GpuMatrices;

static Mat4 identity(void)
{
    Mat4 m = {{{0}}};
    int i;
    for (i = 0; i < 4; ++i) m.a[i][i] = 1.0;
    return m;
}

static Mat4 multiply(Mat4 left, Mat4 right)
{
    Mat4 out = {{{0}}};
    int row, col, k;
    for (row = 0; row < 4; ++row)
        for (col = 0; col < 4; ++col)
            for (k = 0; k < 4; ++k)
                out.a[row][col] += left.a[row][k] * right.a[k][col];
    return out;
}

static Mat4 translate(double x, double y, double z)
{
    Mat4 m = identity();
    m.a[0][3] = x;
    m.a[1][3] = y;
    m.a[2][3] = z;
    return m;
}

static double radians(double degrees) { return degrees * (PI / 180.0); }

static Mat4 rotate_x(double degrees)
{
    Mat4 m = identity();
    double c = cos(radians(degrees)), s = sin(radians(degrees));
    m.a[1][1] = c;  m.a[1][2] = -s;
    m.a[2][1] = s;  m.a[2][2] = c;
    return m;
}

static Mat4 rotate_y(double degrees)
{
    Mat4 m = identity();
    double c = cos(radians(degrees)), s = sin(radians(degrees));
    m.a[0][0] = c;  m.a[0][2] = -s;
    m.a[2][0] = s;  m.a[2][2] = c;
    return m;
}

static Mat4 rotate_z(double degrees)
{
    Mat4 m = identity();
    double c = cos(radians(degrees)), s = sin(radians(degrees));
    m.a[0][0] = c;  m.a[0][1] = -s;
    m.a[1][0] = s;  m.a[1][1] = c;
    return m;
}

static int to_q16(double value, int32_t *word)
{
    double scaled = round(value * Q16_SCALE);
    if (!isfinite(scaled) || scaled < (double)INT32_MIN ||
        scaled > (double)INT32_MAX)
        return 0;
    *word = (int32_t)scaled;
    return 1;
}

static int build_matrices(const Scene *s, GpuMatrices *out)
{
    Mat4 m, v, p, t;
    int row, col;
    if (s->width <= 0 || s->height <= 0 ||
        !(s->focal_pixels > 0.0) || !(s->near_distance > 0.0))
        return 0;

    /* A column vector encounters object roll, pitch, yaw, then position. */
    t = multiply(rotate_x(s->object_angle.pitch),
                 rotate_z(s->object_angle.roll));
    m = multiply(translate(s->object_position.x,
                           s->object_position.y,
                           s->object_position.z),
                 multiply(rotate_y(s->object_angle.yaw), t));

    /* Exactly the inverse-camera order shown in the PDF's full example. */
    t = multiply(rotate_y(-s->camera_angle.yaw),
                 translate(-s->camera_position.x,
                           -s->camera_position.y,
                           -s->camera_position.z));
    v = multiply(rotate_z(-s->camera_angle.roll),
                 multiply(rotate_x(-s->camera_angle.pitch), t));

    /* h.x = focal*x_camera, h.y = focal*y_camera, h.w = z_camera. */
    p = (Mat4){{{0}}};
    p.a[0][0] = s->focal_pixels;
    p.a[1][1] = s->focal_pixels;
    p.a[2][2] = 1.0;
    p.a[3][2] = 1.0;

    out->model = m;
    out->view = v;
    out->projection = p;
    out->final = multiply(p, multiply(v, m));

    for (row = 0; row < 4; ++row)
        for (col = 0; col < 4; ++col)
            if (!to_q16(out->final.a[row][col],
                        &out->final_q16[row * 4 + col]))
                return 0;
    return to_q16(s->near_distance, &out->near_q16) && out->near_q16 > 0;
}

/* Decode the actual Q16.16 words and apply them using double precision.
 * This checks coefficient quantization, not a hardware accumulator's rounding.
 */
static void apply_q16(const GpuMatrices *g, Vec3 local, double h[4])
{
    double v[4] = {local.x, local.y, local.z, 1.0};
    int row, col;
    for (row = 0; row < 4; ++row) {
        h[row] = 0.0;
        for (col = 0; col < 4; ++col)
            h[row] += ((double)g->final_q16[row * 4 + col] / Q16_SCALE)
                      * v[col];
    }
}

static int project_q16(const Scene *s, const GpuMatrices *g, Vec3 local,
                       double *screen_x, double *screen_y, double *depth)
{
    double h[4];
    apply_q16(g, local, h);
    if (h[3] < s->near_distance) return 0;
    *screen_x = s->width / 2.0 + h[0] / h[3];
    *screen_y = s->height / 2.0 - h[1] / h[3];
    *depth = h[3];
    return 1;
}

static void print_matrix_words(const GpuMatrices *g)
{
    int row, col;
    printf("Final matrix: 16 signed Q16.16 words, row-major, top to bottom:\n");
    for (row = 0; row < 4; ++row) {
        for (col = 0; col < 4; ++col)
            printf("%08" PRIX32 "%s",
                   (uint32_t)g->final_q16[row * 4 + col],
                   col == 3 ? "" : " ");
        putchar('\n');
    }
    printf("Near distance Q16.16: %08" PRIX32 "\n",
           (uint32_t)g->near_q16);
}

/* Independent point-by-point reference: deliberately does not use matrices. */
static Vec3 reference_rotate_x(Vec3 p, double angle)
{
    double c = cos(radians(angle)), s = sin(radians(angle));
    Vec3 out = {p.x, c * p.y - s * p.z, s * p.y + c * p.z};
    return out;
}

static Vec3 reference_rotate_y(Vec3 p, double angle)
{
    double c = cos(radians(angle)), s = sin(radians(angle));
    Vec3 out = {c * p.x - s * p.z, p.y, s * p.x + c * p.z};
    return out;
}

static Vec3 reference_rotate_z(Vec3 p, double angle)
{
    double c = cos(radians(angle)), s = sin(radians(angle));
    Vec3 out = {c * p.x - s * p.y, s * p.x + c * p.y, p.z};
    return out;
}

static Vec3 reference_camera_point(const Scene *s, Vec3 p)
{
    p = reference_rotate_z(p, s->object_angle.roll);
    p = reference_rotate_x(p, s->object_angle.pitch);
    p = reference_rotate_y(p, s->object_angle.yaw);
    p.x += s->object_position.x; p.y += s->object_position.y;
    p.z += s->object_position.z;
    p.x -= s->camera_position.x; p.y -= s->camera_position.y;
    p.z -= s->camera_position.z;
    p = reference_rotate_y(p, -s->camera_angle.yaw);
    p = reference_rotate_x(p, -s->camera_angle.pitch);
    p = reference_rotate_z(p, -s->camera_angle.roll);
    return p;
}

static int reference_project(const Scene *s, Vec3 p,
                             double *x, double *y, double *depth)
{
    p = reference_camera_point(s, p);
    if (p.z < s->near_distance) return 0;
    *x = s->width / 2.0 + s->focal_pixels * p.x / p.z;
    *y = s->height / 2.0 - s->focal_pixels * p.y / p.z;
    *depth = p.z;
    return 1;
}

static int check_matrix_vector(const char *name, const Scene *s, Vec3 vertex,
                               const double *known_expected)
{
    GpuMatrices g;
    double h[4], expected[4];
    double v[4] = {vertex.x, vertex.y, vertex.z, 1.0};
    const char *labels[4] = {"X", "Y", "Z", "W"};
    /* Each rounded coefficient differs by at most half a Q16.16 unit. */
    double tolerance = (fabs(vertex.x) + fabs(vertex.y) + fabs(vertex.z) + 1.0)
                       / (2.0 * Q16_SCALE) + 1e-9;
    int row, col, passed = 1;
    Vec3 camera_point;

    printf("\n=== %s ===\n", name);
    printf("Camera position: (%.3f, %.3f, %.3f)\n",
           s->camera_position.x, s->camera_position.y, s->camera_position.z);
    printf("Camera rotation: pitch %.3f, yaw %.3f, roll %.3f degrees\n",
           s->camera_angle.pitch, s->camera_angle.yaw, s->camera_angle.roll);
    printf("Object position: (%.3f, %.3f, %.3f)\n",
           s->object_position.x, s->object_position.y, s->object_position.z);
    printf("Object rotation: pitch %.3f, yaw %.3f, roll %.3f degrees\n",
           s->object_angle.pitch, s->object_angle.yaw, s->object_angle.roll);
    printf("Vertex inside object: (%.3f, %.3f, %.3f); input W = 1\n",
           vertex.x, vertex.y, vertex.z);
    printf("View: %d x %d, focal %.3f pixels, near %.3f\n",
           s->width, s->height, s->focal_pixels, s->near_distance);
    if (!build_matrices(s, &g)) {
        puts("FAIL: matrix could not be generated");
        return 0;
    }
    apply_q16(&g, vertex, h);
    puts("\nFull 4x4 matrix (Q16.16 words decoded to readable decimals):");
    for (row = 0; row < 4; ++row) {
        printf("[ ");
        for (col = 0; col < 4; ++col)
            printf("%13.6f ", g.final_q16[row * 4 + col] / Q16_SCALE);
        puts("]");
    }
    printf("\nMatrix * vertex column [%.3f, %.3f, %.3f, 1]:\n",
           vertex.x, vertex.y, vertex.z);
    for (row = 0; row < 4; ++row) {
        printf("%s = ", labels[row]);
        for (col = 0; col < 4; ++col)
            printf("(%.6f * %.3f)%s",
                   g.final_q16[row * 4 + col] / Q16_SCALE, v[col],
                   col == 3 ? "" : " + ");
        printf(" = %.6f\n", h[row]);
    }
    printf("\nResult (X, Y, Z, W) = (%.6f, %.6f, %.6f, %.6f)\n",
           h[0], h[1], h[2], h[3]);
    puts("X/Y include focal length; Z and W both hold camera depth here.");

    camera_point = reference_camera_point(s, vertex);
    expected[0] = s->focal_pixels * camera_point.x;
    expected[1] = s->focal_pixels * camera_point.y;
    expected[2] = camera_point.z;
    expected[3] = camera_point.z;
    if (known_expected != NULL)
        for (row = 0; row < 4; ++row) expected[row] = known_expected[row];
    printf("Expected from %s:\n", known_expected != NULL ?
           "hand calculation" : "separate step-by-step rotations and translation");
    printf("(%.6f, %.6f, %.6f, %.6f)\n",
           expected[0], expected[1], expected[2], expected[3]);
    printf("Allowed coefficient-rounding error: %.9f per output\n", tolerance);
    for (row = 0; row < 4; ++row) {
        int ok = isfinite(h[row]) && fabs(h[row] - expected[row]) <= tolerance;
        printf("%s %s: error %.9f\n", ok ? "PASS" : "FAIL",
               labels[row], fabs(h[row] - expected[row]));
        passed &= ok;
    }
    return passed;
}

static int matrix_test(void)
{
    const Scene simple = {
        {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, 640, 480, 320, 1
    };
    const Scene rotated = {
        {10, 4, 20}, {30, 20, 10}, {2, 1, 5}, {15, 5, 3}, 640, 480, 320, 1
    };
    const double expected[4] = {-320, -320, 4, 4};
    int passed = check_matrix_vector("Simple known-answer test", &simple,
                                     (Vec3){-1, -1, 4}, expected);
    passed &= check_matrix_vector("PDF example with all rotations", &rotated,
                                   (Vec3){1, 2, 3}, NULL);
    puts(passed ? "\nALL FOUR-OUTPUT MATRIX TESTS PASSED" :
                  "\nFOUR-OUTPUT MATRIX TESTS FAILED");
    return passed ? 0 : 1;
}

static int check_point(const char *name, const Scene *s, Vec3 point,
                       double expected_x, double expected_y,
                       int use_independent_reference)
{
    GpuMatrices g;
    double x, y, z;
    if (!build_matrices(s, &g) || !project_q16(s, &g, point, &x, &y, &z)) {
        printf("FAIL %s: build or projection failed\n", name);
        return 0;
    }
    if (use_independent_reference) {
        double reference_x, reference_y, reference_z;
        if (!reference_project(s, point, &reference_x,
                               &reference_y, &reference_z)) {
            printf("FAIL %s: reference rejected point\n", name);
            return 0;
        }
        expected_x = reference_x;
        expected_y = reference_y;
        if (fabs(z - reference_z) > 0.001) {
            printf("FAIL %s: depth %.6f, expected %.6f\n",
                   name, z, reference_z);
            return 0;
        }
    }
    if (fabs(x - expected_x) > 0.02 || fabs(y - expected_y) > 0.02) {
        printf("FAIL %s: pixel (%.6f, %.6f), expected (%.6f, %.6f)\n",
               name, x, y, expected_x, expected_y);
        return 0;
    }
    printf("PASS %s: pixel (%.6f, %.6f), depth %.6f\n", name, x, y, z);
    return 1;
}

static int self_test(void)
{
    Scene s = {{0, 0, 0}, {0, 0, 0}, {0, 0, 0},
               {0, 0, 0}, 640, 480, 320, 1};
    GpuMatrices g;
    int passed = 1;
    passed &= check_point("triangle A, no rotation", &s,
                          (Vec3){-1, -1, 4}, 240, 320, 0);
    passed &= check_point("triangle B, no rotation", &s,
                          (Vec3){1, -1, 4}, 400, 320, 0);
    passed &= check_point("triangle C, no rotation", &s,
                          (Vec3){0, 1, 4}, 320, 160, 0);
    if (!build_matrices(&s, &g) ||
        g.final_q16[0] != 0x01400000 ||
        g.final_q16[5] != 0x01400000 ||
        g.final_q16[10] != 0x00010000 ||
        g.final_q16[14] != 0x00010000) {
        puts("FAIL identity-case Q16.16 matrix words");
        passed = 0;
    } else {
        puts("PASS identity-case Q16.16 matrix words");
    }
    s.camera_position = (Vec3){2, 1, 5};
    passed &= check_point("camera translation", &s,
                          (Vec3){3, 2, 9}, 400, 160, 0);
    s.camera_position = (Vec3){0, 0, 0};
    s.object_angle.yaw = 90;
    passed &= check_point("object yaw 90 degrees", &s,
                          (Vec3){1, 0, 0}, 320, 240, 0);

    /* The fully rotated object and camera given on page 3 of gpu.pdf. */
    s.object_position = (Vec3){10, 4, 20};
    s.object_angle = (Angles){30, 20, 10};
    s.camera_position = (Vec3){2, 1, 5};
    s.camera_angle = (Angles){15, 5, 3};
    passed &= check_point("PDF example, local origin", &s,
                          (Vec3){0, 0, 0}, 0, 0, 1);
    passed &= check_point("PDF example, second vertex", &s,
                          (Vec3){1, 2, 3}, 0, 0, 1);
    passed &= (matrix_test() == 0);
    puts(passed ? "ALL MATRIX TESTS PASSED" : "MATRIX TESTS FAILED");
    return passed ? 0 : 1;
}

/* Scene inputs use real numbers and angles in degrees. Optional edges are
 * sampled into vertices on the CPU; the FPGA still plots only individual points.
 * Output: magic,width,height,near,count,16 matrix words,then XYZ vertex words.
 */
static int export_scene(const char *input_path, const char *output_path)
{
    enum { MAX_POINTS = 16384 };
    static Vec3 points[MAX_POINTS];
    static int32_t vertex_words[MAX_POINTS][3];
    Scene scene = {{0,0,6}, {30,20,0}, {0,0,0}, {0,0,0}, 640,480,320,1};
    GpuMatrices gpu;
    FILE *input, *output;
    char line[512], key[32];
    unsigned count=0, line_number=0, i;
    int ok=1;
    if (strcmp(input_path, output_path) == 0) {
        fputs("Scene input and generated output must be different files.\n", stderr);
        return 1;
    }
    input=fopen(input_path,"r");
    if (!input) { perror(input_path); return 1; }
    while (fgets(line,sizeof(line),input)) {
        ++line_number;
        if (sscanf(line,"%31s",key)!=1 || key[0]=='#') continue;
        if (strcmp(key,"camera")==0 || strcmp(key,"object")==0) {
            Vec3 *p = strcmp(key,"camera")==0 ? &scene.camera_position : &scene.object_position;
            Angles *a = strcmp(key,"camera")==0 ? &scene.camera_angle : &scene.object_angle;
            ok=sscanf(line,"%*s %lf %lf %lf %lf %lf %lf",
                &p->x,&p->y,&p->z,&a->pitch,&a->yaw,&a->roll)==6;
        } else if (strcmp(key,"view")==0) {
            ok=sscanf(line,"%*s %lf %lf",&scene.focal_pixels,&scene.near_distance)==2;
        } else if (strcmp(key,"vertex")==0) {
            Vec3 p = {0,0,0};
            ok=count<MAX_POINTS && sscanf(line,"%*s %lf %lf %lf",&p.x,&p.y,&p.z)==3;
            if (ok) points[count++]=p;
        } else if (strcmp(key,"edge")==0) {
            Vec3 a = {0,0,0}, b = {0,0,0};
            unsigned samples = 0;
            ok=sscanf(line,"%*s %lf %lf %lf %lf %lf %lf %u",
                &a.x,&a.y,&a.z,&b.x,&b.y,&b.z,&samples)==7;
            if (ok) ok=samples>=2 && samples<=MAX_POINTS-count;
            if (ok) for (i=0;i<samples;++i) {
                double t=(double)i/(samples-1);
                points[count++]=(Vec3){a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t,a.z+(b.z-a.z)*t};
            }
        } else ok=0;
        if (!ok) break;
    }
    if (ferror(input)) ok=0;
    fclose(input);
    if (!ok || count==0) {
        fprintf(stderr,"Invalid scene near line %u, or no vertices (limit %d).\n",line_number,MAX_POINTS);
        return 1;
    }
    if (!build_matrices(&scene,&gpu)) {
        fputs("Invalid view or matrix outside Q16.16 range.\n",stderr); return 1;
    }
    for (i=0;i<count;++i)
        if (!to_q16(points[i].x,&vertex_words[i][0]) ||
            !to_q16(points[i].y,&vertex_words[i][1]) ||
            !to_q16(points[i].z,&vertex_words[i][2])) {
            fprintf(stderr,"Vertex %u is outside Q16.16 range.\n",i); return 1;
        }
    output=fopen(output_path,"w");
    if (!output) { perror(output_path); return 1; }
    fprintf(output,"47505531\n00000280\n000001E0\n%08" PRIX32 "\n%08" PRIX32 "\n",
            (uint32_t)gpu.near_q16,(uint32_t)count);
    for (i=0;i<16;++i) fprintf(output,"%08" PRIX32 "\n",(uint32_t)gpu.final_q16[i]);
    for (i=0;i<count;++i) fprintf(output,"%08" PRIX32 " %08" PRIX32 " %08" PRIX32 "\n",
        (uint32_t)vertex_words[i][0],(uint32_t)vertex_words[i][1],(uint32_t)vertex_words[i][2]);
    ok=!ferror(output);
    if (fclose(output)!=0) ok=0;
    if (!ok) { fputs("Failed to write complete scene.\n",stderr); return 1; }
    printf("Camera (%.3f,%.3f,%.3f), pitch/yaw/roll (%.3f,%.3f,%.3f)\n",
        scene.camera_position.x,scene.camera_position.y,scene.camera_position.z,
        scene.camera_angle.pitch,scene.camera_angle.yaw,scene.camera_angle.roll);
    printf("Object (%.3f,%.3f,%.3f), pitch/yaw/roll (%.3f,%.3f,%.3f)\n",
        scene.object_position.x,scene.object_position.y,scene.object_position.z,
        scene.object_angle.pitch,scene.object_angle.yaw,scene.object_angle.roll);
    printf("Exported matrix and %u vertices to %s\n",count,output_path);
    return 0;
}

int main(int argc, char **argv)
{
    /* Replace these values with each object's and camera's state on the CPU. */
    const Scene pdf_example = {
        {10, 4, 20}, {30, 20, 10},
        {2, 1, 5}, {15, 5, 3},
        640, 480, 320.0, 1.0
    };
    GpuMatrices gpu;
    if (argc == 4 && strcmp(argv[1], "--scene") == 0)
        return export_scene(argv[2], argv[3]);
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0)
        return self_test();
    if (argc == 2 && strcmp(argv[1], "--matrix-test") == 0)
        return matrix_test();
    if (argc != 1) {
        fprintf(stderr, "Usage: %s [--self-test | --matrix-test | --scene input.txt output.hex]\n", argv[0]);
        return 2;
    }
    if (!build_matrices(&pdf_example, &gpu)) {
        fputs("Matrix or near value does not fit signed Q16.16.\n", stderr);
        return 1;
    }
    print_matrix_words(&gpu);
    return 0;
}
