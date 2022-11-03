#! /bin/bash

KIB=$((8*1024))
MIB=$((${KIB}*1024))
GIB=$((${MIB}*1024))
path="/proc/sys/vm/nr_hugepages"
# 规格配置
# 虚拟机 osd 1GB uss 2GB
# 物理机 osd 2GB uss 3GB
declare -A cluster_map
if [ -z ${2} ];then
	cluster_map=([virtual_osd]=$((1*${GIB})) [virtual_uss]=$((2*${GIB})) [physics_osd]=$((2*${GIB})) [physics_uss]=$((3*${GIB})))
else
	cluster_map=([virtual_osd]=$((${2}*${MIB})) [virtual_uss]=$((${2}*${MIB})) [physics_osd]=$((${2}*${MIB})) [physics_uss]=$((${2}*${MIB})))
fi
productName=$(virt-what)

function osd_config(){
	# 物理机,虚拟机规格配置不同
	if [ -z $productName ];then
		# 物理机需要分配多大的大页内存空间
		alloc_page_size=${cluster_map['physics_osd']}
	else
		# 虚拟机需要分配多大的大页内存空间
		alloc_page_size=${cluster_map['virtual_osd']}
	fi
}

function uss_config(){
	if [ -z $productName ];then
		# 物理机需要分配多大的大页内存空间
		alloc_page_size=${cluster_map['physics_uss']}
	else
		# 虚拟机需要分配多大的大页内存空间
		alloc_page_size=${cluster_map['virtual_uss']}
	fi
}

case ${1} in
	"osd")
		osd_config productName
		;;
	"uss")
		uss_config productName
		;;
		*)
		echo "输入用途 hugepage.sh osd|uss"
		exit 1
		;;
esac

# echo $alloc_page_size


#系统剩余内存阈值限制
MemFreeLimit=$((${MIB}*1))
#系统可用内存大小
MemFreeSize=$(($(grep -e "^MemFree" /proc/meminfo | tr -s " " ":" | cut -d":" -f 2)*${KIB}))
#每个大页大小
pagesize=$(($(grep -e "^Hugepagesize" /proc/meminfo | tr -s " " ":" | cut -d":" -f 2)*${KIB}))
#已有大页个数
pagecount=$(grep -e "^HugePages_Free" /proc/meminfo | tr -s " " ":" | cut -d":" -f 2)
#可用大页内存空间
HugepageFreeSize=$((${pagecount}*${pagesize}))


echo "**************************************"
# 系统可用大页内存不满足时，为节点新增加大页内存
if [ $alloc_page_size -gt $HugepageFreeSize ];then
        # 还差多少页需要分配
        need_page_size=$((${alloc_page_size}-${HugepageFreeSize}))
        # echo "还需 $((${need_page_size}/${KIB})) KIB 页大小"
        # 去除限额可分配的内存空间
        distributable=$((${MemFreeSize}-${MemFreeLimit}))
        # echo "去除限额可用内存空间 $((${distributable}/${KIB})) KIB"
        # 可用空间大于需要分配空间进行分配
        if [ $distributable -ge $need_page_size ];then
        	# 判断当前已有大页内存，在此基础上增加
                need_page=$((${alloc_page_size}/${pagesize}))
                already_page=$(cat ${path})
                alloc_page=$((${need_page}+${already_page}))
                echo "总页数 ${alloc_page}，新增加 ${need_page} 页"
                echo ${alloc_page} > ${path}
                success_alloc=$(cat ${path})
                unassigned=$((${alloc_page}-${success_alloc}))
                echo "**************************************"
                echo "成功分配 ${success_alloc}, 未分配 ${unassigned}"
                surplus_cache_size=$(($(grep -e "^MemFree" /proc/meminfo | tr -s " " ":" | cut -d":" -f 2)*${KIB}))
                surplus_alloc_page=$((${surplus_cache_size}/${pagesize}))
                grep HugePage /proc/meminfo
                echo "**************************************"
                echo "当前剩余内存"
                grep -e "^MemFree" /proc/meminfo
                echo "还可分配 ${surplus_alloc_page} 个 $((${pagesize}/${KIB})) KIB 大页内存。"
                echo "**************************************"
                exit 0
        else
                need_cache_size=$((${need_page_size}-${distributable}))
                echo "系统可用内存空间不足，缺少 $((${need_cache_size}/${KIB})) KIB 内存空间。"
                echo "**************************************"
                exit 1
        fi
else
        echo "系统已有$((${pagesize}/${KIB})) KIB 大页内存 ${pagecount} 个。"
        echo "**************************************"
        exit 0
fi
