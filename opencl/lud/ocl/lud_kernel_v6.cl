#ifndef BLOCK_SIZE
	#define BLOCK_SIZE 64
#endif

#define DIA_UNROLL    2
#define PERI_UNROLL   8
#define PERI_SIMD     1
#define PERI_COMPUTE  2
#define INTER_SIMD    1
#define INTER_COMPUTE 3

#define LMEM_SIZE BLOCK_SIZE*BLOCK_SIZE
#define DIA_LMEM_ATTRIB __attribute__((memory, numbanks(2), bankwidth(4*DIA_UNROLL), doublepump, numreadports(3), numwriteports(1)))
#define PERI_LMEM_ATTRIB __attribute__((memory, numbanks(1), bankwidth(4*PERI_UNROLL), doublepump))

#include "../common/opencl_kernel_common.h"

__attribute__((reqd_work_group_size(BLOCK_SIZE,1,1)))
__kernel void lud_diagonal(__global volatile float* RESTRICT m, 
                                             int             matrix_dim,
                                             int             offset)
{ 
	int i,j;
	int tx = get_local_id(0);
	__local float DIA_LMEM_ATTRIB shadow_row[LMEM_SIZE], DIA_LMEM_ATTRIB shadow_col[LMEM_SIZE];

	int array_offset = offset * matrix_dim + offset;
	for(i=0; i < BLOCK_SIZE; i++)
	{
		shadow_row[i * BLOCK_SIZE + tx] = m[array_offset + tx];
		shadow_col[tx * BLOCK_SIZE + i] = m[array_offset + tx];
		array_offset += matrix_dim;
	}
  
	barrier(CLK_LOCAL_MEM_FENCE);
	
	for(i=0; i < BLOCK_SIZE-1; i++)
	{
		if (tx>i)
		{
			float sum = 0.0f;
			#pragma unroll DIA_UNROLL
			for(j=0; j < i; j++)
			{
				sum += shadow_row[tx * BLOCK_SIZE + j] * shadow_col[i * BLOCK_SIZE + j];
			}
			shadow_row[tx * BLOCK_SIZE + i] = (shadow_row[tx * BLOCK_SIZE + i] - sum) / shadow_col[i * BLOCK_SIZE + i];
			shadow_col[i * BLOCK_SIZE + tx] = shadow_row[tx * BLOCK_SIZE + i];
		}

		barrier(CLK_LOCAL_MEM_FENCE);

		if (tx>i)
		{
			float sum = 0.0f;
			#pragma unroll DIA_UNROLL
			for(j=0; j < i+1; j++)
			{
				sum += shadow_row[(i+1) * BLOCK_SIZE + j] * shadow_col[tx * BLOCK_SIZE + j];
			}
			shadow_row[(i+1) * BLOCK_SIZE + tx] -= sum;
			shadow_col[tx * BLOCK_SIZE + (i+1)] = shadow_row[(i+1) * BLOCK_SIZE + tx];
		}

		barrier(CLK_LOCAL_MEM_FENCE);
	}

	array_offset = (offset+1) * matrix_dim + offset;
	for(i=1; i < BLOCK_SIZE; i++)
	{
		m[array_offset + tx] = shadow_row[i * BLOCK_SIZE + tx];
		array_offset += matrix_dim;
	}
}

__attribute__((num_compute_units(PERI_COMPUTE)))
__attribute__((num_simd_work_items(PERI_SIMD)))
__attribute__((reqd_work_group_size(BLOCK_SIZE*2,1,1)))
__kernel void lud_perimeter(__global volatile float* RESTRICT m,
                                              int             matrix_dim,
                                              int             offset)
{
	int i, j, array_offset[3];
	int idx, txg;
	__local float PERI_LMEM_ATTRIB dia_row[LMEM_SIZE], PERI_LMEM_ATTRIB dia_col[LMEM_SIZE], peri_row[LMEM_SIZE], peri_col[LMEM_SIZE];

	int  bx = get_group_id(0);
	int  tx = get_local_id(0);

	idx = tx % BLOCK_SIZE;
	txg = tx / BLOCK_SIZE;

	array_offset[0] = (offset + txg) * matrix_dim + offset;
	array_offset[1] = (offset + txg) * matrix_dim + (bx+1) * BLOCK_SIZE + offset;
	array_offset[2] = (offset + txg + (bx+1) * BLOCK_SIZE) * matrix_dim + offset;

	for (i=0; i < BLOCK_SIZE; i=i+2)
	{
		dia_row[(i + txg) * BLOCK_SIZE + idx]  = m[array_offset[0] + idx];
		dia_col[idx * BLOCK_SIZE + (i + txg)]  = m[array_offset[0] + idx];
		peri_row[idx * BLOCK_SIZE + (i + txg)] = m[array_offset[1] + idx];
		peri_col[(i + txg) * BLOCK_SIZE + idx] = m[array_offset[2] + idx];

		array_offset[0] += 2 * matrix_dim;
		array_offset[1] += 2 * matrix_dim;
		array_offset[2] += 2 * matrix_dim;
	}

	barrier(CLK_LOCAL_MEM_FENCE);

	if (tx < BLOCK_SIZE)
	{ //peri-row
		idx = tx;
		int peri_row_array_offset = offset * matrix_dim + (bx+1) * BLOCK_SIZE + offset;
		for(i=0; i < BLOCK_SIZE; i++)
		{
			float sum = 0.0f;
			#pragma unroll PERI_UNROLL
			for (j=0; j < i; j++)
			{
				sum += dia_row[i * BLOCK_SIZE + j] * peri_row[idx * BLOCK_SIZE + j];
			}
			peri_row[idx * BLOCK_SIZE + i] -= sum;

			m[peri_row_array_offset + idx] = peri_row[idx * BLOCK_SIZE + i];
			peri_row_array_offset += matrix_dim;
		}
	}
	else
	{ //peri-col
		idx = tx - BLOCK_SIZE;
		for(i=0; i < BLOCK_SIZE; i++)
		{
			float sum = 0.0f;
			#pragma unroll PERI_UNROLL
			for(j=0; j < i; j++)
			{
				sum += dia_col[i * BLOCK_SIZE + j] * peri_col[idx * BLOCK_SIZE + j];
			}
			peri_col[idx * BLOCK_SIZE + i] = (peri_col[idx * BLOCK_SIZE + i] - sum) / dia_col[i * BLOCK_SIZE + i];
		}
	}
	barrier(CLK_LOCAL_MEM_FENCE);

	if (tx >= BLOCK_SIZE)
	{ //peri-col
		idx = tx - BLOCK_SIZE;
		int peri_col_array_offset = (offset + (bx+1) * BLOCK_SIZE) * matrix_dim + offset;
		for(i=0; i < BLOCK_SIZE; i++)
		{
			m[peri_col_array_offset + idx] =  peri_col[i * BLOCK_SIZE + idx];
			peri_col_array_offset += matrix_dim;
		}
	}
}

__attribute__((num_compute_units(INTER_COMPUTE)))
__attribute__((num_simd_work_items(INTER_SIMD)))
__attribute__((reqd_work_group_size(BLOCK_SIZE,BLOCK_SIZE,1)))
__kernel void lud_internal(__global float* RESTRICT m,
                                    int             matrix_dim,
                                    int             offset)
{
	int i;
	float sum;
	__local float peri_row[LMEM_SIZE], peri_col[LMEM_SIZE];

	int  bx = get_group_id(0);
	int  by = get_group_id(1);
  
	int  tx = get_local_id(0);
	int  ty = get_local_id(1);

	int global_row_id = offset + (by+1) * BLOCK_SIZE;
	int global_col_id = offset + (bx+1) * BLOCK_SIZE;

	peri_row[ty * BLOCK_SIZE + tx] = m[(offset + ty) * matrix_dim + global_col_id + tx];
	peri_col[ty * BLOCK_SIZE + tx] = m[(global_row_id + ty) * matrix_dim + offset + tx];

	barrier(CLK_LOCAL_MEM_FENCE);

	sum = 0;
	#pragma unroll
	for (i=0; i < BLOCK_SIZE; i++)
	{
		sum += peri_col[ty * BLOCK_SIZE + i] * peri_row[i * BLOCK_SIZE + tx];
	}
	m[(global_row_id + ty) * matrix_dim + global_col_id + tx] -= sum;
}
