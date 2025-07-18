/*
  ScatterAlloc: Massively Parallel Dynamic Memory Allocation for the GPU.
  http://www.icg.tugraz.at/project/mvp

  Copyright (C) 2012 Institute for Computer Graphics and Vision,
                     Graz University of Technology
  Copyright (C) 2014 Institute of Radiation Physics,
                     Helmholtz-Zentrum Dresden - Rossendorf

  Author(s):  Markus Steinberger - steinberger ( at ) icg.tugraz.at
              Rene Widera - r.widera ( at ) hzdr.de

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.
*/

#pragma once

#include "heaputils.cuh"

#include <stdint.h>
#include <stdio.h>

namespace GPUTools
{
  template<uint pagesize = 65536, uint accessblocks = 8, uint regionsize = 16, uint wastefactor = 2, bool use_coalescing = true, bool resetfreedpages = false>
  class ManagedHeap
  {
  public:
    typedef ManagedHeap<pagesize,accessblocks,regionsize,wastefactor,use_coalescing,resetfreedpages> myType;
    static const uint _pagesize = pagesize;
    static const uint _accessblocks = accessblocks;
    static const uint _regionsize = regionsize;
    static const uint _wastefactor = wastefactor;
    static const bool _use_coalescing = use_coalescing;
    static const bool _resetfreedpages = resetfreedpages;

    /**
     * Allocate the ManagedHeap object in CUDA managed memory
     */
    void* operator new(size_t size)
    {
      void* ptr = nullptr;
      CUDA_CHECKED_CALL(cudaMallocManaged(&ptr, size));
      return ptr;
    }

    /**
     * Free the ManagedHeap object from CUDA managed memory
     */
    void operator delete(void* ptr) noexcept
    {
      cudaFree(ptr);
    }

    /**
     * Host side constructor taking a memory heap size argument.
     */
    __host__ ManagedHeap(size_t memsize = 8*1024U*1024U);

    /**
     * Host side destructor that also cleans up the allocated memory.
     */
    __host__ ~ManagedHeap();

    /** Count, how many elements can be allocated at maximum
     *
     * Takes an input size and determines, how many elements of this size can
     * be allocated with the CreationPolicy Scatter. This will return the
     * maximum number of free slots of the indicated size. It is not
     * guaranteed where these slots are (regarding fragmentation). Therefore,
     * the practically usable number of slots might be smaller. This function
     * is executed in parallel. Speedup can possibly be increased by a higher
     * amount of parallel workers.
     *
     * @param slotSize the size of allocatable elements to count
     */
    __host__ unsigned getAvailableSlots(size_t const slotSize);

    /**
     * Count how many bytes can be allocated at maximum
     *
     * Traverses the entire heap and accumulates the amount of memory that is
     * currently unused. This number is purely theoretical as fragmentation may
     * prevent allocations of this size. The algorithm mirrors the strategy
     * used for getAvailableSlots and is executed in parallel on the device.
     */
    __host__ size_t getAvailableBytes();

    /**
     * alloc allocates the requested number of bytes via the heap
     * @return pointer to the memory region, 0 if it fails
     */
    __host__ __device__ void* alloc(uint bytes);

    /**
     * dealloc frees the memory regions previously acllocted
     * @param mem pointer to the memory region to free
     */
    __host__ __device__ void dealloc(void* mem);

  private:

#if _DEBUG || ANALYSEHEAP
  public:
#endif
    static const uint minChunkSize0 = pagesize/(32*32);
    static const uint minChunkSize1 = 0x10;
    static const uint dataAlignment = 0x10; //needs to be power of two!
    static const uint HierarchyThreshold =  (pagesize - 2*sizeof(uint))/33;

    //this are the parameters for hashing
    //the values have not been fully evaluated yet, so altering them
    //might strongly increase performance
    static const uint hashingK = 38183;
    static const uint hashingDistMP = 17497;  //128;
    static const uint hashingDistWP = 1; //1; 2;
    static const uint hashingDistWPRel = 1; //1; 4;

    /**
     * Page Table Entry struct
     * The PTE holds basic information about each page
     */
    struct PTE
    {
      uint chunksize;
      uint count;
      uint bitmask;

      __device__ void init()
      {
        chunksize = 0;
        count = 0;
        bitmask = 0;
      }
    };
    /**
     * Page struct
     * The page struct is used to access the data on the page more efficiently
     * and to clear the area on the page, which might hold bitsfields later one
     */
    struct PAGE
    {
      char data[pagesize];

      /**
       * The pages init method
       * This method initializes the region on the page which might hold
       * bit fields when the page is used for a small chunk size
       * @param previous_chunksize the chunksize which was uses for the page before
       */
      __device__ void init(uint previous_chunksize = 0)
      {
        //TODO: we can speed this up for pages being freed, because we know the
        //chunksize used before (these bits must be zero again)

        //init the entire data which can hold bitfields
        uint max_bits = min(32*32,pagesize/minChunkSize1);
        uint max_entries = GPUTools::divup<uint>(max_bits/8,sizeof(uint))*sizeof(uint);
        uint* write = (uint*)(data+(pagesize-max_entries));
        while(write < (uint*)(data + pagesize))
          *write++ = 0;
      }
    };

    // the data used by the allocator
    volatile PTE* _ptes;
    volatile uint* _regions;
    PAGE* _page;
    uint _numpages;
    size_t _memsize;
    uint _pagebasedMutex;
    volatile uint _firstFreePageBased;
    volatile uint _firstfreeblock;
    void *_pool;

    /**
     * randInit should create an random offset which can be used
     * as the initial position in a bitfield
     */
    __device__ inline uint randInit()
    {
      //start with the laneid offset
      return laneid();
    }

    /**
     * randInextspot delivers the next free spot in a bitfield
     * it searches for the next unset bit to the left of spot and
     * returns its offset. if there are no unset bits to the left
     * then it wraps around
     * @param bitfield the bitfield to be searched for
     * @param spot the spot from which to search to the left
     * @param spots number of bits that can be used
     * @return next free spot in the bitfield
     */
    __device__ inline uint nextspot(uint bitfield, uint spot, uint spots)
    {
      //wrap around the bitfields from the current spot to the left
      bitfield = ((bitfield >> (spot + 1)) | (bitfield << (spots - (spot + 1))))&((1<<spots)-1);
      //compute the step from the current spot in the bitfield
      uint step = __ffs(~bitfield);
      //and return the new spot
      return (spot + step) % spots;
    }

    /**
     * usespot marks finds one free spot in the bitfield, marks it and returns its offset
     * @param bitfield pointer to the bitfield to use
     * @param spots overall number of spots the bitfield is responsible for
     * @return if there is a free spot it returns the spot'S offset, otherwise -1
     */
    __device__ inline int usespot(uint *bitfield, uint spots)
    {
      //get first spot
      uint spot = randInit() % spots;
      for(;;)
      {
        uint mask = 1 << spot;
        uint old = atomicOr(bitfield, mask);
        if( (old & mask) == 0)
          return spot;
        // note: __popc(old) == spots should be sufficient,
        //but if someone corrupts the memory we end up in an endless loop in here...
        if(__popc(old) >= spots)
          return -1;
        spot = nextspot(old, spot, spots);
      }
    }

    /**
     * addChunkHierarchy finds a free chunk on a page which uses bit fields on the page
     * @param chunksize the chunksize of the page
     * @param fullsegments the number of full segments on the page (a 32 bits on the page)
     * @param additional_chunks the number of additional chunks in last segment (less than 32 bits on the page)
     * @param page the page to use
     * @return pointer to a free chunk on the page, 0 if we were unable to obtain a free chunk
     */
    __device__ inline void* addChunkHierarchy(uint chunksize, uint fullsegments, uint additional_chunks, uint page)
    {
      uint segments = fullsegments + (additional_chunks > 0 ? 1 : 0);
      uint spot = randInit() % segments;
      uint mask = _ptes[page].bitmask;
      if((mask & (1 << spot)) != 0)
        spot = nextspot(mask, spot, segments);
      uint tries = segments - __popc(mask);
      uint* onpagemasks = (uint*)(_page[page].data + chunksize*(fullsegments*32 + additional_chunks));
      for(uint i = 0; i < tries; ++i)
      {
        int hspot = usespot(onpagemasks + spot, spot < fullsegments ? 32 : additional_chunks);
        if(hspot != -1)
          return _page[page].data + (32*spot + hspot)*chunksize;
        else
          atomicOr((uint*)&_ptes[page].bitmask, 1 << spot);
        spot = nextspot(mask, spot, segments);
      }
      return 0;
    }

    /**
     * addChunkNoHierarchy finds a free chunk on a page which uses the bit fields of the pte only
     * @param chunksize the chunksize of the page
     * @param page the page to use
     * @param spots the number of chunks which fit on the page
     * @return pointer to a free chunk on the page, 0 if we were unable to obtain a free chunk
     */
    __device__ inline void* addChunkNoHierarchy(uint chunksize, uint page, uint spots)
    {
      int spot = usespot((uint*)&_ptes[page].bitmask, spots);
      if(spot == -1)
        return 0; //that should be impossible :)
      return _page[page].data + spot*chunksize;
    }

    /**
     * tryUsePage tries to use the page for the allocation request
     * @param page the page to use
     * @param chunksize the chunksize of the page
     * @return pointer to a free chunk on the page, 0 if we were unable to obtain a free chunk
     */
    __device__ inline void* tryUsePage(uint page, uint chunksize)
    {
      void* chunk_ptr = NULL;
      //increase the fill level
      uint filllevel = atomicAdd((uint*)&(_ptes[page].count), 1);
      //recheck chunk size (it could be that the page got freed in the meanwhile...)
      if(!resetfreedpages || _ptes[page].chunksize == chunksize)
      {
        if(chunksize <= HierarchyThreshold)
        {
          //more chunks than can be covered by the pte's single bitfield can be used
          uint segmentsize = chunksize*32 + sizeof(uint);
          uint fullsegments = 0;
          uint additional_chunks = 0;
          fullsegments = pagesize / segmentsize;
          additional_chunks = max(0,(int)pagesize - (int)fullsegments*segmentsize - (int)sizeof(uint))/chunksize;
          if(filllevel < fullsegments * 32 + additional_chunks)
            chunk_ptr = addChunkHierarchy(chunksize, fullsegments, additional_chunks, page);
        }
        else
        {
          uint chunksinpage = min(pagesize / chunksize, 32);
          if(filllevel < chunksinpage)
            chunk_ptr = addChunkNoHierarchy(chunksize, page, chunksinpage);
        }
      }

      //this one is full/not usable
      if(chunk_ptr == NULL)
        atomicSub((uint*)&(_ptes[page].count), 1);

      return chunk_ptr;
    }

    /**
     * allocChunked tries to allocate the demanded number of bytes on one of the pages
     * @param bytes the number of bytes to allocate
     * @return pointer to a free chunk on a page, 0 if we were unable to obtain a free chunk
     */
    __device__ void* allocChunked(uint bytes)
    {
      uint pagesperblock = _numpages/accessblocks;
      uint reloff = warpSize*bytes / pagesize;
      uint startpage = (bytes*hashingK + hashingDistMP*smid() + (hashingDistWP+hashingDistWPRel*reloff)*warpid() ) % pagesperblock;
      uint maxchunksize = min(pagesize,wastefactor*bytes);
      uint startblock = _firstfreeblock;
      uint ptetry = startpage + startblock*pagesperblock;
      uint checklevel = regionsize*3/4;
      for(uint finder = 0; finder < 2; ++finder)
      {
        for(uint b = startblock; b < accessblocks; ++b)
        {
          while(ptetry < (b+1)*pagesperblock)
          {
            uint region = ptetry/regionsize;
            uint regionfilllevel = _regions[region];
            if(regionfilllevel < checklevel )
            {
              for( ; ptetry < (region+1)*regionsize; ++ptetry)
              {
                uint chunksize = _ptes[ptetry].chunksize;
                if(chunksize >= bytes && chunksize <= maxchunksize)
                {
                  void * res = tryUsePage(ptetry, chunksize);
                  if(res != 0)  return res;
                }
                else if(chunksize == 0)
                {
                  //lets open up a new page
                  //it is already padded
                  uint new_chunksize = max(bytes,minChunkSize1);
                  uint beforechunksize = atomicCAS((uint*)&_ptes[ptetry].chunksize, 0, new_chunksize);
                  if(beforechunksize == 0)
                  {
                    void * res = tryUsePage(ptetry, new_chunksize);
                    if(res != 0)  return res;
                  }
                  else if(beforechunksize >= bytes &&  beforechunksize <= maxchunksize)
                  {
                    //someone else aquired the page, but we can also use it
                    void * res = tryUsePage(ptetry, beforechunksize);
                    if(res != 0)  return res;
                  }
                }
              }
              //could not alloc in region, tell that
              if(regionfilllevel + 1 <= regionsize)
                atomicMax((uint*)(_regions + region), regionfilllevel+1);
            }
            else
              ptetry += regionsize;
              //ptetry = (region+1)*regionsize;
          }
          //randomize the thread writing the info
          //if(warpid() + laneid() == 0)
          if(b > startblock)
            _firstfreeblock = b;
        }

        //we are really full :/ so lets search every page for a spot!
        startblock = 0;
        checklevel = regionsize + 1;
        ptetry = 0;
      }
      return 0;
    }

    /**
     * deallocChunked frees the chunk on the page and updates all data accordingly
     * @param mem pointer to the chunk
     * @param page the page the chunk is on
     * @param chunksize the chunksize used for the page
     */
    __device__ void deallocChunked(void* mem, uint page, uint chunksize)
    {
      uint inpage_offset = ((char*)mem - _page[page].data);
      if(chunksize <= HierarchyThreshold)
      {
        //one more level in hierarchy
        uint segmentsize = chunksize*32 + sizeof(uint);
        uint fullsegments = pagesize / segmentsize;
        uint additional_chunks = max(0,(int)(pagesize - fullsegments*segmentsize) - (int)sizeof(uint))/chunksize;
        uint segment = inpage_offset / (chunksize*32);
        uint withinsegment = (inpage_offset - segment*(chunksize*32))/chunksize;
        //mark it as free
        uint* onpagemasks = (uint*)(_page[page].data + chunksize*(fullsegments*32 + additional_chunks));
        uint old = atomicAnd(onpagemasks + segment, ~(1 << withinsegment));

        // always do this, since it might fail due to a race-condition with addChunkHierarchy
        atomicAnd((uint*)&_ptes[page].bitmask, ~(1 << segment));
      }
      else
      {
        uint segment = inpage_offset / chunksize;
        atomicAnd((uint*)&_ptes[page].bitmask, ~(1 << segment));
      }
      //reduce filllevel as free
      uint oldfilllevel = atomicSub((uint*)&_ptes[page].count, 1);


      if(resetfreedpages)
      {
        if(oldfilllevel == 1)
        {
          //this page now got free!
          // -> try lock it
          uint old = atomicCAS((uint*)&_ptes[page].count, 0, pagesize);
          if(old == 0)
          {
            //clean the bits for the hierarchy
            _page[page].init();
            //remove chunk information
            _ptes[page].chunksize = 0;
            __threadfence();
            //unlock it
            atomicSub((uint*)&_ptes[page].count, pagesize);
          }
        }
      }

      //meta information counters ... should not be changed by too many threads, so..
      if(oldfilllevel == pagesize / 2 / chunksize)
      {
        uint region = page / regionsize;
        _regions[region] = 0;
        uint block = region * regionsize * accessblocks / _numpages ;
        if(warpid() + laneid() == 0)
          atomicMin((uint*)&_firstfreeblock, block);
      }
    }

    /**
     * markpages marks a fixed number of pages as used
     * @param startpage first page to mark
     * @param pages number of pages to mark
     * @param bytes number of overall bytes to mark pages for
     * @return true on success, false if one of the pages is not free
     */
    __device__ bool markpages(uint startpage, uint pages, uint bytes)
    {
      int abortPage = -1;
      for(uint trypage = startpage; trypage < startpage + pages; ++trypage)
      {
        uint old = atomicCAS((uint*)&_ptes[trypage].chunksize, 0, bytes);
        if(old != 0)
        {
          abortPage = trypage;
          break;
        }
      }
      if(abortPage == -1)
        return true;
      for(uint trypage = startpage; trypage < abortPage; ++trypage)
        atomicCAS((uint*)&_ptes[trypage].chunksize, bytes, 0);
      return false;
    }

    /**
     * allocPageBasedSingleRegion tries to allocate the demanded number of bytes on a continues sequence of pages
     * @param startpage first page to be used
     * @param endpage last page to be used
     * @param bytes number of overall bytes to mark pages for
     * @return pointer to the first page to use, 0 if we were unable to use all the requested pages
     */
    __device__ void* allocPageBasedSingleRegion(uint startpage, uint endpage, uint bytes)
    {
      uint pagestoalloc = divup(bytes, pagesize);
      uint freecount = 0;
      bool left_free = false;
      for(uint search_page = startpage+1; search_page > endpage; )
      {
        --search_page;
        if(_ptes[search_page].chunksize == 0)
        {
          if(++freecount == pagestoalloc)
          {
            //try filling it up
            if(markpages(search_page, pagestoalloc, bytes))
            {
              //mark that we filled up everything up to here
              if(!left_free)
                atomicCAS((uint*)&_firstFreePageBased, startpage, search_page - 1);
              return _page[search_page].data;
            }
          }
        }
        else
        {
          left_free = true;
          freecount = 0;
        }
      }
      return 0;
    }

    /**
     * allocPageBasedSingle tries to allocate the demanded number of bytes on a continues sequence of pages
     * @param bytes number of overall bytes to mark pages for
     * @return pointer to the first page to use, 0 if we were unable to use all the requested pages
     * @pre only a single thread of a warp is allowed to call the function concurrently
     */
    __device__ void* allocPageBasedSingle(uint bytes)
    {
      //acquire mutex
      while(atomicExch(&_pagebasedMutex,1) != 0);
      //search for free spot from the back
      uint spage = _firstFreePageBased;
      void* res = allocPageBasedSingleRegion(spage, 0, bytes);
      if(res == 0)
        //also check the rest of the pages
          res = allocPageBasedSingleRegion(_numpages, spage, bytes);

      //free mutex
      atomicExch(&_pagebasedMutex,0);
      return res;
    }
    /**
     * allocPageBased tries to allocate the demanded number of bytes on a continues sequence of pages
     * @param bytes number of overall bytes to mark pages for
     * @return pointer to the first page to use, 0 if we were unable to use all the requested pages
     */
    __device__ void* allocPageBased(uint bytes)
    {
      //this is rather slow, but we dont expect that to happen often anyway

      //only one thread per warp can acquire the mutex
      void* res = 0;
      warp_serial
        res = allocPageBasedSingle(bytes);
      return res;
    }

    /**
     * deallocPageBased frees the memory placed on a sequence of pages
     * @param mem pointer to the first page
     * @param page the first page
     * @param bytes the number of bytes to be freed
     */
    __device__ void deallocPageBased(void* mem, uint page, uint bytes)
    {
        uint pages = divup(bytes,pagesize);
        for(uint p = page; p < page+pages; ++p)
          _page[p].init();
        __threadfence();
        for(uint p = page; p < page+pages; ++p)
          atomicCAS((uint*)&_ptes[p].chunksize, bytes, 0);
        atomicMax((uint*)&_firstFreePageBased, page+pages-1);
    }


    /**
     * alloc_internal_direct allocates the requested number of bytes via the heap with coalescing disabled
     * @param bytes number of bytes to allocate
     * @return pointer to the allocated memory
     */
    __device__ void* alloc_internal_direct(uint bytes)
    {
      if(bytes == 0)
        return 0;
      //take care of padding
      bytes = (bytes + dataAlignment - 1) & ~(dataAlignment-1);
      if(bytes < pagesize)
        //chunk based
        return allocChunked(bytes);
      else
        //allocate a range of pages
        return allocPageBased(bytes);
    }

    /**
     * dealloc_internal_direct frees the memory regions previously acllocted via the heap with coalescing disabled
     * @param mempointer to the memory region to free
     */
    __device__ void dealloc_internal_direct(void* mem)
    {
      if(mem == 0)
        return;
      //lets see on which page we are on
      uint page = ((char*)mem - (char*)_page)/pagesize;
      uint chunksize = _ptes[page].chunksize;

      //is the pointer the beginning of a chunk?
      uint inpage_offset = ((char*)mem - _page[page].data);
      uint block = inpage_offset/chunksize;
      uint inblockoffset = inpage_offset - block*chunksize;
      if(inblockoffset != 0)
      {
        uint* counter = (uint*)(_page[page].data + block*chunksize);
        //coalesced mem free
        uint old = atomicSub(counter, 1);
        if(old != 1)
          return;
        mem = (void*) counter;
      }

      if(chunksize < pagesize)
        deallocChunked(mem, page, chunksize);
      else
        deallocPageBased(mem, page, chunksize);
    }

    /**
     * alloc_internal_coalesced combines the memory requests of all threads within a warp and allocates them together
     * idea is based on XMalloc: A Scalable Lock-free Dynamic Memory Allocator for Many-core Machines
     * doi: 10.1109/CIT.2010.206
     * @param bytes number of bytes to allocate
     * @return pointer to the allocated memory
     */
    __device__ void* alloc_internal_coalesced(uint bytes)
    {
      //shared structs to use
      __shared__ uint warp_sizecounter[32];
      __shared__ char* warp_res[32];

      // identify the participating threads at the beginning of this function
      auto mask = __activemask();

      //take care of padding
      bytes = (bytes + dataAlignment - 1) & ~(dataAlignment-1);

      bool can_use_coalescing = false;
      uint myoffset = 0;
      uint warpid = GPUTools::warpid();

      //init with initial counter
      warp_sizecounter[warpid] = 16;

#if __CUDA_ARCH__ >= 700
      // ensure all threads of the warp have written the initial counter
      __syncwarp(mask);
#endif

      bool coalescible = bytes > 0 && bytes < (pagesize / 32);
      uint threadcount = __popc(__ballot_sync(mask, coalescible));

      if (coalescible && threadcount > 1)
      {
        myoffset = atomicAdd(&warp_sizecounter[warpid], bytes);
        can_use_coalescing = true;
      }

#if __CUDA_ARCH__ >= 700
      // wait for all atomicAdds to finish so warp_sizecounter holds the final value
      __syncwarp(mask);
#endif

      uint req_size = bytes;
      if (can_use_coalescing)
        req_size = (myoffset == 16) ? warp_sizecounter[warpid] : 0;

      char* myalloc = (char*)alloc_internal_direct(req_size);
      if (req_size && can_use_coalescing)
      {
        warp_res[warpid] = myalloc;
        if (myalloc != 0)
          *(uint*)myalloc = threadcount;
      }
      __threadfence_block();
#if __CUDA_ARCH__ >= 700
      __syncwarp(mask);
#endif

      void *myres = myalloc;
      if(can_use_coalescing)
      {
        if(warp_res[warpid] != 0)
          myres = warp_res[warpid] + myoffset;
        else
          myres = 0;
      }
      return myres;
    }

    /**
     * dealloc_internal_coalesced frees the memory regions previously acllocted via alloc_internal<true>
     * @param mempointer to the memory region to free
     */
    __device__ void dealloc_internal_coalesced(void* mem)
    {
      if(mem == 0)
        return;
      //lets see on which page we are on
      uint page = ((char*)mem - (char*)_page)/pagesize;
      uint chunksize = _ptes[page].chunksize;

      //is the pointer the beginning of a chunk?
      uint inpage_offset = ((char*)mem - _page[page].data);
      uint block = inpage_offset/chunksize;
      uint inblockoffset = inpage_offset - block*chunksize;
      if(inblockoffset != 0)
      {
        uint* counter = (uint*)(_page[page].data + block*chunksize);
        //coalesced mem free
        uint old = atomicSub(counter, 1);
        if(old != 1)
          return;
        mem = (void*) counter;
      }

      if(chunksize < pagesize)
        deallocChunked(mem, page, chunksize);
      else
        deallocPageBased(mem, page, chunksize);
    }


  public:

    /**
     * init inits the heap data structures
     * the init method must be called before the heap can be used. the method can be called
     * with an arbitrary number of threads, which will increase the inits efficiency
     * @param memory pointer to the memory used for the heap
     * @param memsize size of the memory in bytes
     */
    __device__ void init(void* memory, size_t memsize)
    {
      uint linid = threadIdx.x + blockDim.x*(threadIdx.y + threadIdx.z*blockDim.y);
      uint threads = blockDim.x*blockDim.y*blockDim.z;
      uint linblockid = blockIdx.x + gridDim.x*(blockIdx.y + blockIdx.z*gridDim.y);
      uint blocks =  gridDim.x*gridDim.y*gridDim.z;
      linid = linid + linblockid*threads;

      uint numregions = ((unsigned long long)memsize)/( ((unsigned long long)regionsize)*(sizeof(PTE)+pagesize)+sizeof(uint));
      uint numpages = numregions*regionsize;
      PAGE* page = (PAGE*)(memory);
      //sec check for alignment
      PointerEquivalent alignmentstatus = ((PointerEquivalent)page) & (dataAlignment -1);
      if(alignmentstatus != 0)
      {
        page =(PAGE*)(((PointerEquivalent)page) + dataAlignment - alignmentstatus);
        if(linid == 0) printf("Heap Warning: memory to use not 16 byte aligned...\n");
      }
      PTE* ptes = (PTE*)(page + numpages);
      uint* regions = (uint*)(ptes + numpages);
      //sec check for mem size
      if( (void*)(regions + numregions) > (((char*)memory) + memsize) )
      {
        --numregions;
        numpages = min(numregions*regionsize,numpages);
        if(linid == 0) printf("Heap Warning: needed to reduce number of regions to stay within memory limit\n");
      }
      //if(linid == 0) printf("Heap info: wasting %d bytes\n",(((POINTEREQUIVALENT)memory) + memsize) - (POINTEREQUIVALENT)(regions + numregions));

      threads = threads*blocks;

      for(uint i = linid; i < numpages; i+= threads)
      {
        ptes[i].init();
        page[i].init();
      }
      for(uint i = linid; i < numregions; i+= threads)
        regions[i] = 0;

      if(linid == 0)
      {
        _memsize = memsize;
        _numpages = numpages;
        _ptes = (volatile PTE*)ptes;
        _page = page;
        _regions =  regions;
        _firstfreeblock = 0;
        _pagebasedMutex = 0;
        _firstFreePageBased = numpages-1;
        _pool = memory;

        if( (char*) (_page+numpages) > (char*)(memory) + memsize)
          printf("error in heap alloc: numpages too high\n");
      }

    }


    /** counts how many elements of a size fit inside a given page
     *
     * Examines a (potentially already used) page to find how many elements
     * of size chunksize still fit on the page. This includes hierarchically
     * organized pages and empty pages. The algorithm determines the number
     * of chunks in the page in a manner similar to the allocation algorithm
     * of CreationPolicies::Scatter.
     *
     * @param page the number of the page to examine. The page needs to be
     *        formatted with a chunksize and potentially a hierarchy.
     * @param chunksize the size of element that should be placed inside the
     *        page. This size must be appropriate to the formatting of the
     *        page.
     */
    __device__ unsigned countFreeChunksInPage(uint32_t page, uint32_t chunksize){
      uint32_t filledChunks = _ptes[page].count;
      if(chunksize <= HierarchyThreshold)
      {
        uint32_t segmentsize = chunksize*32 + sizeof(uint32_t); //each segment can hold 32 2nd-level chunks
        uint32_t fullsegments = pagesize / segmentsize; //there might be space for more than 32 segments with 32 2nd-level chunks
        uint32_t additional_chunks = max(0,(int)pagesize - (int)fullsegments*segmentsize - (int)sizeof(uint32_t))/chunksize;
        uint32_t level2Chunks = fullsegments * 32 + additional_chunks;

        //if(filledChunks > 0 || __popc(_ptes[page].bitmask) != 0){
        //  uint32_t freeChunks = level2Chunks-filledChunks;
        //  uint* onpagemasks = (uint*)(_page[page].data + chunksize*(fullsegments*32 + additional_chunks));
        //  printf("Page: %u chunksize: %u  segmentsize: %u  additionalchunks: %u  chunksInPage: %u  filledChunks: %u  freeChunks %u  _ptes.bitmask: %X  onPageMasks(%u): %X %X %X %X %X %X %X %X\n",
        //      page, _ptes[page].chunksize, segmentsize, additional_chunks, level2Chunks, filledChunks, freeChunks, _ptes[page].bitmask, fullsegments+1,
        //      onpagemasks[0],
        //      onpagemasks[1],
        //      onpagemasks[2],
        //      onpagemasks[3],
        //      onpagemasks[4],
        //      onpagemasks[5],
        //      onpagemasks[6],
        //      onpagemasks[7]
        //      );
        //}
        return level2Chunks - filledChunks;
      }else{
        uint32_t chunksinpage = min(pagesize / chunksize, 32); //without hierarchy, there can not be more than 32 chunks
        return chunksinpage - filledChunks;
      }
    }

    /** counts the number of available slots inside the heap
     *
     * Searches the heap for all possible locations of an element with size
     * slotSize. The used traversal algorithms are similar to the allocation
     * strategy of CreationPolicies::Scatter, to ensure comparable results.
     * There are 3 different algorithms, based on the size of the requested
     * slot: 1 slot spans over multiple pages, 1 slot fits in one chunk
     * within a page, 1 slot fits in a fraction of a chunk.
     *
     * @param slotSize the amount of bytes that a single slot accounts for
     * @param gid the id of the thread. this id does not have to correspond
     *        with threadId.x, but there must be a continuous range of ids
     *        beginning from 0.
     * @param stride the stride should be equal to the number of different
     *        gids (and therefore of value max(gid)-1)
     */
    __device__ unsigned getAvailableSlotsDeviceFunction(size_t slotSize, int gid, int stride)
    {
      unsigned slotcount = 0;
      if(slotSize < pagesize){ // multiple slots per page
        for(uint32_t currentpage = gid; currentpage < _numpages; currentpage += stride){
          uint32_t maxchunksize = min(pagesize, wastefactor*(uint32_t)slotSize);
          uint32_t region = currentpage/regionsize;
          uint32_t regionfilllevel = _regions[region];

          uint32_t chunksize = _ptes[currentpage].chunksize;
          if(chunksize >= slotSize && chunksize <= maxchunksize){ //how many chunks left? (each chunk is big enough)
            slotcount += countFreeChunksInPage(currentpage, chunksize);
          }else if(chunksize == 0){
            chunksize  = max((uint32_t)slotSize, minChunkSize1); //ensure minimum chunk size
            slotcount += countFreeChunksInPage(currentpage, chunksize); //how many chunks fit in one page?
          }else{
            continue; //the chunks on this page are too small for the request :(
          }
        }
      }else{ // 1 slot needs multiple pages
        if(gid > 0) return 0; //do this serially
        uint32_t pagestoalloc = divup((uint32_t)slotSize, pagesize);
        uint32_t freecount = 0;
        for(uint32_t currentpage = _numpages; currentpage > 0;){ //this already includes all superblocks
          --currentpage;
          if(_ptes[currentpage].chunksize == 0){
            if(++freecount == pagestoalloc){
              freecount = 0;
              ++slotcount;
            }
          }else{ // the sequence of free pages was interrupted
            freecount = 0;
          }
        }
      }
      return slotcount;
    }

    /** Count the number of free bytes in the heap
     *
     * Traverses the heap similarly to getAvailableSlotsDeviceFunction and
     * accumulates the remaining memory. The result is theoretical and might
     * not be fully allocatable due to fragmentation.
     */
    __device__ size_t getAvailableBytesDeviceFunction(int gid, int stride)
    {
      size_t bytecount = 0;
      for(uint32_t currentpage = gid; currentpage < _numpages; currentpage += stride){
        uint32_t chunksize = _ptes[currentpage].chunksize;
        if(chunksize == 0){
          bytecount += pagesize;
        }else if(chunksize < pagesize){
          bytecount += (size_t)countFreeChunksInPage(currentpage, chunksize) * chunksize;
        }
      }
      return bytecount;
    }
  };

  /**
   * global init heap method
   */
  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor,  bool use_coalescing, bool resetfreedpages>
  __global__ void initHeap(ManagedHeap<pagesize, accessblocks, regionsize, wastefactor, use_coalescing, resetfreedpages>* heap, void* heapmem, size_t memsize)
  {
    heap->init(heapmem, memsize);
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor,  bool use_coalescing, bool resetfreedpages>
  __host__ ManagedHeap<pagesize,accessblocks,regionsize,wastefactor,use_coalescing,resetfreedpages>::ManagedHeap(size_t memsize)
  {
    void* pool;
    CUDA_CHECKED_CALL(cudaMallocManaged(&pool, memsize));
    initHeap<<<1,256>>>(this, pool, memsize);
    CUDA_CHECK_ERROR();
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor,  bool use_coalescing, bool resetfreedpages>
  __host__ ManagedHeap<pagesize,accessblocks,regionsize,wastefactor,use_coalescing,resetfreedpages>::~ManagedHeap()
  {
    cudaFree(_pool);
  }

  /**
   * global init heap method
   */
  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor,  bool use_coalescing, bool resetfreedpages>
  __global__ void heapAllocKernel(ManagedHeap<pagesize, accessblocks, regionsize, wastefactor, use_coalescing, resetfreedpages>* heap, size_t bytes, void** result)
  {
    if(threadIdx.x==0 && blockIdx.x==0 && result != nullptr)
      *result = heap->alloc(bytes);
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor, bool use_coalescing, bool resetfreedpages>
  __host__ __device__ void* ManagedHeap<pagesize,accessblocks,regionsize,wastefactor,use_coalescing,resetfreedpages>::alloc(uint bytes)
  {
#if __CUDA_ARCH__
    if(use_coalescing)
      return alloc_internal_coalesced(bytes);
    else
      return alloc_internal_direct(bytes);
#else
    void* h_res = nullptr;
    void** d_res;
    CUDA_CHECKED_CALL(cudaMalloc(&d_res, sizeof(void*)));
    GPUTools::heapAllocKernel<<<1,1>>>(this, bytes, d_res);
    CUDA_CHECK_ERROR();
    CUDA_CHECKED_CALL(cudaDeviceSynchronize());
    CUDA_CHECKED_CALL(cudaMemcpy(&h_res, d_res, sizeof(void*), cudaMemcpyDeviceToHost));
    cudaFree(d_res);
    return h_res;
#endif
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor, bool use_coalescing, bool resetfreedpages>
  __global__ void heapDeallocKernel(ManagedHeap<pagesize, accessblocks, regionsize, wastefactor, use_coalescing, resetfreedpages>* heap, void* ptr){
    if(threadIdx.x==0 && blockIdx.x==0)
      heap->dealloc(ptr);
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor,  bool use_coalescing, bool resetfreedpages>
  __host__ __device__ void ManagedHeap<pagesize,accessblocks,regionsize,wastefactor,use_coalescing,resetfreedpages>::dealloc(void* mem)
  {
#if __CUDA_ARCH__
    if(use_coalescing)
      dealloc_internal_coalesced(mem);
    else
      dealloc_internal_direct(mem);
#else
    heapDeallocKernel<<<1,1>>>(this, mem);
    CUDA_CHECK_ERROR();
    CUDA_CHECKED_CALL(cudaDeviceSynchronize());
#endif
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor,  bool use_coalescing, bool resetfreedpages>
  __global__ void getAvailableSlotsKernel(ManagedHeap<pagesize, accessblocks, regionsize, wastefactor, use_coalescing, resetfreedpages>* heap, size_t slotSize, unsigned* slots){
    int gid       = threadIdx.x + blockIdx.x*blockDim.x;
    int nWorker   = gridDim.x * blockDim.x;
    unsigned temp = heap->getAvailableSlotsDeviceFunction(slotSize, gid, nWorker);
    if(temp) atomicAdd(slots, temp);
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor, bool use_coalescing, bool resetfreedpages>
  __global__ void getAvailableBytesKernel(ManagedHeap<pagesize, accessblocks, regionsize, wastefactor, use_coalescing, resetfreedpages>* heap, size_t* bytes){
    int gid     = threadIdx.x + blockIdx.x*blockDim.x;
    int nWorker = gridDim.x * blockDim.x;
    size_t temp = heap->getAvailableBytesDeviceFunction(gid, nWorker);
    if(temp) atomicAdd((unsigned long long*)bytes, (unsigned long long)temp);
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor, bool use_coalescing, bool resetfreedpages>
  __host__ unsigned ManagedHeap<pagesize,accessblocks,regionsize,wastefactor,use_coalescing,resetfreedpages>::getAvailableSlots(size_t const slotSize){
    unsigned h_slots = 0;
    unsigned* d_slots;
    CUDA_CHECKED_CALL(cudaMalloc((void**) &d_slots, sizeof(unsigned)));
    CUDA_CHECKED_CALL(cudaMemcpy(d_slots, &h_slots, sizeof(unsigned), cudaMemcpyHostToDevice));

    getAvailableSlotsKernel<<<64,256>>>(this,slotSize, d_slots);
    CUDA_CHECKED_CALL(cudaDeviceSynchronize());
    CUDA_CHECK_ERROR();

    CUDA_CHECKED_CALL(cudaMemcpy(&h_slots, d_slots, sizeof(unsigned), cudaMemcpyDeviceToHost));
    cudaFree(d_slots);
    return h_slots;
  }

  template<uint pagesize, uint accessblocks, uint regionsize, uint wastefactor, bool use_coalescing, bool resetfreedpages>
  __host__ size_t ManagedHeap<pagesize,accessblocks,regionsize,wastefactor,use_coalescing,resetfreedpages>::getAvailableBytes(){
    size_t h_bytes = 0;
    size_t* d_bytes;
    CUDA_CHECKED_CALL(cudaMalloc((void**) &d_bytes, sizeof(size_t)));
    CUDA_CHECKED_CALL(cudaMemcpy(d_bytes, &h_bytes, sizeof(size_t), cudaMemcpyHostToDevice));

    getAvailableBytesKernel<<<64,256>>>(this, d_bytes);
    CUDA_CHECKED_CALL(cudaDeviceSynchronize());
    CUDA_CHECK_ERROR();

    CUDA_CHECKED_CALL(cudaMemcpy(&h_bytes, d_bytes, sizeof(size_t), cudaMemcpyDeviceToHost));
    cudaFree(d_bytes);
    return h_bytes;
  }
}
